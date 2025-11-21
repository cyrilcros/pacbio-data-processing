#!/usr/bin/env nextflow

nextflow.enable.dsl=2

// --- Input parameters ---
params.local_paths_file = null
params.outdir = "results"

// --- Workflow ---
workflow {
    // Read local paths from file and create channel with file paths only
    channel
        .fromPath(params.local_paths_file)
        .splitText()
        .map { line -> line.trim() }
        .filter { line -> line && !line.startsWith('#') }
        .map { local_path -> 
            def run_id = local_path.replaceAll(/\.raw\.tar\.gz$/, '').split('/')[-1]
            [run_id, file(local_path)] 
        }
        .set { ch_local_files }

    // Extract files one at a time (no download needed)
    extract_local_files(ch_local_files)
    
    // Create meta map from extract output
    extract_local_files.out
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

process extract_local_files {
    tag "${run_id}"
    maxForks 1  // Process only one file at a time
    
    input:
    tuple val(run_id), path(tarball)

    output:
    tuple val(run_id), path("data"), env(ASSAY_ID)

    script:
    """
    echo "Extracting ${tarball.name} for ${run_id}..."
    
    echo "Input file size:"
    ls -lh "${tarball}"
    
    # Extract the tarball
    mkdir -p data
    tar -xzf "${tarball}"
    
    # Move all extracted files to data directory (handles nested directories)
    find . -type f ! -name "${tarball.name}" -exec mv {} data/ \\;
    
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