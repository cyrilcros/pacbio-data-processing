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

    // Filter and collect failed reports
    validate_checksums.out.md5_check
        .filter { tuple ->
            def (_run_id, _assay_id, _report, status) = tuple
            status == 'FAIL'
        }
        .map { tuple -> tuple[2] } // Just the report file
        .collectFile(name: 'failed_checksums.txt', storeDir: params.outdir)

    // View results
    validate_checksums.out.md5_check.view { tuple ->
        def (run_id, assay_id, _report, status) = tuple
        "${status}: ${run_id} (${assay_id})"
    }

    // Filter successful runs and extract HiFi reads
    validate_checksums.out.md5_check
        .filter { tuple ->
            def (_run_id, _assay_id, _report, status) = tuple
            status == 'OK'
        }
        .map { tuple ->
            def (run_id, assay_id, _report, _status) = tuple
            [run_id, assay_id]
        }
        .join(validate_checksums.out.subreads)
        .set { ch_validated_subreads }

    // Extract HiFi reads
    extract_hifi_reads(ch_validated_subreads)

    // View HiFi results
    extract_hifi_reads.out.view { tuple ->
        def (run_id, assay_id, hifi_reads) = tuple
        "HIFI: ${run_id} (${assay_id}) -> ${hifi_reads}"
    }
}

// --- Processes ---

process extract_files {
    tag "${run_id}"

    input:
    tuple val(run_id), path(s3_file)

    output:
    tuple val(run_id), path("data")

    script:
    """
    mkdir -p data
    tar -xzf "${s3_file}"
    find . -type f ! -name "${s3_file}" -exec mv {} data/ \\;
    """
}

process validate_checksums {
    tag "${run_id}"

    input:
    tuple val(run_id), path(data_dir)

    output:
    tuple val(run_id), env(ASSAY_ID), path("checksum_report.txt"), env(STATUS), emit: md5_check
    tuple val(run_id), env(ASSAY_ID), path("data/*.metadata.xml"), path("data/*.run.metadata.xml"), path("data/*.sts.xml"), emit: run_metadata
    tuple val(run_id), env(ASSAY_ID), path("data/*.subreads.bam"), path("data/*.subreads.bam.pbi"), path("data/*.subreadset.xml"), emit: subreads

    script:
    """
    export STATUS="FAIL"
    export ASSAY_ID=""
    
    MD5_FILE=\$(ls ${data_dir}/*.md5 2>/dev/null | head -n 1)
    
    if [ -z "\$MD5_FILE" ]; then
        echo "No .md5 file found" > checksum_report.txt
    else
        export ASSAY_ID=\$(basename "\$MD5_FILE" .md5)
        cd ${data_dir}
        if md5sum -c \$(basename "\$MD5_FILE") > "\$OLDPWD/checksum_report.txt" 2>&1; then
            export STATUS="OK"
            
            # Remove leading dots from hidden files after successful validation
            for file in .*metadata.xml; do
                if [ -f "\$file" ]; then
                    mv "\$file" "\${file#.}"
                fi
            done
        fi
    fi
    """
}

process extract_hifi_reads {
    tag "${run_id}"
    conda "bioconda::pbccs=6.4.0"

    input:
    tuple val(run_id), val(assay_id), path(subreads_bam), path(subreads_pbi), path(subreadset_xml)

    output:
    tuple val(run_id), val(assay_id), path("${assay_id}.hifi.bam")

    script:
    """
    ccs ${subreads_bam} ${assay_id}.hifi.bam --min-passes 3 --min-rq 0.99
    """
}