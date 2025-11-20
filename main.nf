#!/usr/bin/env nextflow

nextflow.enable.dsl=2

// --- Input parameters ---
// Parameters will be loaded from params.yml or provided via command line
// Expected parameters: params.s3_paths_file, params.outdir

// --- Log ---
log.info """
         P A C B I O   P R O C E S S I N G
         =================================
         s3_paths_file: ${params.s3_paths_file}
         outdir       : ${params.outdir}
         """.stripIndent()

// --- Workflow ---
workflow {
    Channel
        .fromPath(params.s3_paths_file)
        .splitText()
        .map { it.trim() }
        .filter { it }
        .set { ch_s3_paths }

    ch_s3_paths | untar_and_checksum
}

// --- Processes ---

process untar_and_checksum {
    tag "process ${s3_path.split('/')[-1]}"
    publishDir "${params.outdir}/${s3_path.split('/')[-1].split('\\.')[0]}", mode: 'copy'

    input:
    val s3_path

    output:
    path "checksum_results.txt"

    script:
    """
    # Nextflow stages the S3 file automatically
    # The file will be available with the name from the URL
    S3_FILENAME="${s3_path.split('/')[-1]}"
    tar -xzf "\$S3_FILENAME"

    # Find the md5 file. We assume one per tarball.
    MD5_FILE=\$(find . -type f -name "*.md5" | head -n 1)

    if [ -z "\$MD5_FILE" ]; then
        echo "No .md5 file found in ${s3_path}" > checksum_results.txt
        exit 1
    fi

    # The paths in the md5 file are relative to its location
    MD5_DIR=\$(dirname "\$MD5_FILE")

    # Change to the directory with the md5 file to run the check
    cd "\$MD5_DIR"

    MD5_BASENAME=\$(basename "\$MD5_FILE")

    # Run the checksum and save the output
    md5sum -c "\$MD5_BASENAME" > ../checksum_results.txt
    """
}
