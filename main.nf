#!/usr/bin/env nextflow

nextflow.enable.dsl=2

// --- Input parameters ---
params.s3_paths_file = null
params.outdir = "results"

// --- Workflow ---
workflow {
    // Read S3 paths from file and create channel with URLs only
    channel
        .fromPath(params.s3_paths_file)
        .splitText()
        .map { line -> line.trim() }
        .filter { line -> line && !line.startsWith('#') }
        .map { s3_path -> 
            def run_id = s3_path.replaceAll(/\.raw\.tar\.gz$/, '').split('/')[-1]
            [run_id, s3_path] 
        }
        .set { ch_s3_urls }

    // Download and extract files one at a time
    download_and_extract(ch_s3_urls)
    
    // Create meta map from download output
    download_and_extract.out
        .map { tuple ->
            def (run_id, data_dir, assay_id) = tuple
            def meta = [run_id: run_id, assay_id: assay_id]
            [meta, data_dir]
        }
        .set { ch_with_meta }

    // Validate checksums with meta
    validate_checksums(ch_with_meta)

    // Extract HiFi reads from successful validations (one at a time)
    extract_hifi_reads(validate_checksums.out.subreads)

    // View HiFi results
    extract_hifi_reads.out.hifi.view { tuple ->
        def (meta, hifi_bam, consensusreadset) = tuple
        "HIFI: ${meta.run_id} (${meta.assay_id}) -> ${hifi_bam.name}"
    }
}

// --- Processes ---

process download_and_extract {
    tag "${run_id}"
    maxForks 1  // Process only one file at a time
    
    input:
    tuple val(run_id), val(s3_url)

    output:
    tuple val(run_id), path("data"), env(ASSAY_ID)

    script:
    def filename = s3_url.split('/')[-1]
    """
    echo "Downloading ${filename} for ${run_id}..."
    
    # Download with wget (more reliable for large files)
    wget -O "${filename}" "${s3_url}"
    
    echo "Download completed. File size:"
    ls -lh "${filename}"
    
    echo "Extracting ${filename}..."
    mkdir -p data
    tar -xzf "${filename}"
    find . -type f ! -name "${filename}" -exec mv {} data/ \\;
    
    # Clean up the downloaded archive to save space
    rm "${filename}"
    
    echo "Extraction completed. Files in data:"
    ls -la data/
    
    # Extract assay_id from .md5 file and export as environment variable
    MD5_FILE=\$(ls data/*.md5 2>/dev/null | head -n 1)
    if [ -z "\$MD5_FILE" ]; then
        echo "ERROR: No .md5 file found"
        exit 1
    fi
    export ASSAY_ID=\$(basename "\$MD5_FILE" .md5)
    echo "Found assay_id: \$ASSAY_ID"
    """
}

process validate_checksums {
    tag "${meta.run_id}"
    errorStrategy 'ignore'

    input:
    tuple val(meta), path(data_dir)

    output:
    tuple val(meta), path("data/*.metadata.xml"), path("data/*.run.metadata.xml"), path("data/*.sts.xml"), path("checksum_report.txt"), emit: run_metadata
    tuple val(meta), path("data/*.subreads.bam"), path("data/*.subreads.bam.pbi"), path("data/*.subreadset.xml"), emit: subreads

    script:
    """
    # Check if the specific .md5 file exists
    if [ ! -f "${data_dir}/${meta.assay_id}.md5" ]; then
        echo "No ${meta.assay_id}.md5 file found" > checksum_report.txt
        exit 1
    fi
    
    echo "Starting checksum validation for ${meta.assay_id}..."
    
    # Md5sum check
    cd ${data_dir}
    if md5sum -c "${meta.assay_id}.md5" > ../checksum_report.txt 2>&1; then
        cd ..
        echo "SUCCESS: All checksums passed for ${meta.assay_id}" >> checksum_report.txt
        
        # Remove leading dots from hidden files after successful validation
        cd ${data_dir}
        for file in .*metadata.xml; do
            if [ -f "\$file" ]; then
                cp "\$file" "\${file#.}"
                echo "Copied \$file to \${file#.}" >> ../checksum_report.txt
            fi
        done
    else
        cd ..
        echo "FAILED: Checksum validation failed for ${meta.assay_id}" >> checksum_report.txt
        exit 1
    fi
    """
}

process extract_hifi_reads {
    tag "${meta.run_id}"
    label 'pacbio_ccs'
    conda "bioconda::pbccs=6.4.0"
    publishDir "${params.outdir}/hifi_reads", mode: 'copy'
    errorStrategy 'ignore'
    maxForks 1  // Process only one HiFi extraction at a time

    input:
    tuple val(meta), path(subreads_bam), path(subreads_pbi), path(subreadset_xml)

    output:
    tuple val(meta), path("${meta.assay_id}.hifi_reads.ccs.bam"), path("${meta.assay_id}.ccs.consensusreadset.xml"), emit: hifi, optional: true
    tuple val(meta), path("${meta.assay_id}.ccs.log"), emit: log, optional: true
    tuple val(meta), path("${meta.assay_id}.ccs_reports.json"), path("${meta.assay_id}.hifi_summary.json"), emit: summary, optional: true

    script:
    """
    echo "Starting CCS for ${meta.assay_id} (${meta.run_id})"
    echo "Input files:"
    ls -lh
    echo "Starting HiFi read extraction..."
    ccs \\
        --num-threads ${task.cpus} \\
        --min-passes 3 \\
        --min-rq 0.99 \\
        --log-level INFO \\
        --log-file ${meta.assay_id}.ccs.log \\
        --report-json ${meta.assay_id}.ccs_reports.json \\
        --hifi-summary-json ${meta.assay_id}.hifi_summary.json \\
        ${subreads_bam} \\
        ${meta.assay_id}.hifi_reads.ccs.bam
    echo "HiFi extraction completed for ${meta.assay_id}"
    """
}