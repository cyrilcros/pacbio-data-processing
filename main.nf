#!/usr/bin/env nextflow

nextflow.enable.dsl=2

// --- Input parameters ---
params.s3_paths_file = null
params.outdir = "results"

// --- Workflow ---
workflow {
    // Read S3 paths from file and create channel with file objects
    channel
        .fromPath(params.s3_paths_file)
        .splitText()
        .map { line -> line.trim() }
        .filter { line -> line && !line.startsWith('#') }
        .map { s3_path -> 
            def run_id = s3_path.replaceAll(/\.raw\.tar\.gz$/, '').split('/')[-1]
            [run_id, file(s3_path)] 
        }
        .set { ch_s3_files }

    // Extract files
    extract_files(ch_s3_files)
    
    // Create meta map from extract_files output
    extract_files.out
        .map { tuple ->
            def (run_id, data_dir, assay_id) = tuple
            def meta = [run_id: run_id, assay_id: assay_id]
            [meta, data_dir]
        }
        .set { ch_with_meta }

    // Validate checksums with meta
    validate_checksums(ch_with_meta)

    // Extract HiFi reads from successful validations
    extract_hifi_reads(validate_checksums.out.subreads)

    // View HiFi results
    extract_hifi_reads.out.hifi.view { tuple ->
        def (meta, hifi_reads) = tuple
        "HIFI: ${meta.run_id} (${meta.assay_id}) -> ${hifi_reads}"
    }
}

// --- Processes ---

process extract_files {
    tag "${run_id}"

    input:
    tuple val(run_id), path(s3_file)

    output:
    tuple val(run_id), path("data"), env(ASSAY_ID)

    script:
    """
    mkdir -p data
    tar -xzf "${s3_file}"
    find . -type f ! -name "${s3_file}" -exec mv {} data/ \\;
    
    # Extract assay_id from .md5 file and export as environment variable
    MD5_FILE=\$(ls data/*.md5 2>/dev/null | head -n 1)
    export ASSAY_ID=\$(basename "\$MD5_FILE" .md5)
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
    # Md5sum check
    cd ${data_dir}
    if ! md5sum -c "${meta.assay_id}.md5" > "\$OLDPWD/checksum_report.txt" 2>&1; then
        echo "Checksum validation failed" >> "\$OLDPWD/checksum_report.txt"
        exit 1
    fi
    # Remove leading dots from hidden files after successful validation
    for file in .*metadata.xml; do
        if [ -f "\$file" ]; then
            cp "\$file" "\${file#.}"
        fi
    done
    
    echo "All checksums passed" >> "\$OLDPWD/checksum_report.txt"
    """
}

process extract_hifi_reads {
    tag "${meta.run_id}"
    label 'pacbio_ccs'
    conda "bioconda::pbccs=6.4.0"
    publishDir "${params.outdir}/hifi_reads", mode: 'copy'
    errorStrategy 'ignore'

    input:
    tuple val(meta), path(subreads_bam), path(subreads_pbi), path(subreadset_xml)

    output:
    tuple val(meta), path("${meta.assay_id}.hifi_reads.ccs.bam"), path("${meta.assay_id}.ccs.consensusreadset.xml"), emit: hifi, optional: true
    tuple val(meta), path("${meta.assay_id}.ccs.log"), emit: log, optional: true
    tuple val(meta), path("${meta.assay_id}.ccs_reports.json"), path("${meta.assay_id}.hifi_summary.json"), emit: summary, optional: true

    script:
    """
    echo "Starting CCS for ${meta.assay_id}"
    echo "Input files:"
    ls -la
    
    # Check if ccs command exists
    which ccs || echo "CCS command not found"
    
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
        
    # Create consensusreadset.xml if it doesn't exist
    touch ${meta.assay_id}.ccs.consensusreadset.xml
    """
}