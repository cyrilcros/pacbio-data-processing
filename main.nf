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

    // Extract and validate
    extract_files(ch_s3_files)
    validate_checksums(extract_files.out)

    // Extract HiFi reads from successful validations
    extract_hifi_reads(validate_checksums.out.subreads)

    // View HiFi results
    extract_hifi_reads.out.view { tuple ->
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
    tuple val([run_id: run_id, assay_id: file("data/*.md5")[0].baseName]), path("data")

    script:
    """
    mkdir -p data
    tar -xzf "${s3_file}"
    find . -type f ! -name "${s3_file}" -exec mv {} data/ \\;
    """
}

process validate_checksums {
    tag "${meta}"
    errorStrategy 'ignore'

    input:
    tuple val(meta), path(data_dir)

    output:
    tuple val(meta), path("data/*.metadata.xml"), path("data/*.run.metadata.xml"), path("data/*.sts.xml"), emit: run_metadata
    tuple val(meta), path("data/*.subreads.bam"), path("data/*.subreads.bam.pbi"), path("data/*.subreadset.xml"), emit: subreads

    script:
    """
    # Check if the specific .md5 file exists
    if [ ! -f "${data_dir}/${meta.assay_id}.md5" ]; then
        echo "No ${meta.assay_id}.md5 file found" > checksum_report.txt
        exit 1
    fi
    
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
    
    echo "All checksums passed" > "\$OLDPWD/checksum_report.txt"
    """
}

process extract_hifi_reads {
    tag "${meta}"
    conda "bioconda::pbccs=6.4.0"

    input:
    tuple val(meta), path(subreads_bam), path(subreads_pbi), path(subreadset_xml)

    output:
    tuple val(meta), path("${meta.assay_id}.hifi.bam")

    script:
    """
    ccs ${subreads_bam} ${meta.assay_id}.hifi.bam --min-passes 3 --min-rq 0.99
    """
}