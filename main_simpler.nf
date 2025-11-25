#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
 * PROCESS: Run PacBio CCS
 * Uses label 'pacbio_ccs' to map to the 64 CPU / 128 GB RAM / Conda config
 */
process RUN_CCS {
    tag "$meta.id"
    label 'pacbio_ccs'
    
    // Output results to the directory specified in params.yml
    publishDir "${params.outdir}/ccs_bam", mode: 'copy'

    input:
    tuple val(meta), path(subreads_bam)

    output:
    tuple val(meta), path("*.ccs.bam"), emit: bam
    tuple val(meta), path("*.ccs.bam.pbi"), emit: pbi
    path "*.report.txt", emit: report
    path "*.json", emit: json_report

    script:
    def prefix = "${meta.id}"
    """
    # Run CCS
    # task.cpus is derived from the 'pacbio_ccs' label in nextflow.config (64)
    ccs ${subreads_bam} ${prefix}.ccs.bam \
        --threads ${task.cpus} \
        --report-file ${prefix}.ccs_report.txt \
        --report-json ${prefix}.ccs_report.json \
        --log-level INFO
    """
}

/*
 * WORKFLOW
 */
workflow {

    // 1. Create Channel from TSV
    // - splitCsv parses the tab-separated file
    // - map converts the string path to a File object for staging
    ch_subreads = Channel.fromPath(params.local_paths_file)
        .splitCsv(header: true, sep: '\t')
        .map { row ->
            def meta = [
                id: row.sample,
                run: row.run
            ]
            // We wrap the path string in file() to ensure Nextflow 
            // stages the file correctly on the Slurm node
            def bam_file = file(row.subreads, checkIfExists: true)
            
            return [ meta, bam_file ]
        }

    // 2. Run CCS
    RUN_CCS(ch_subreads)

    // 3. (Optional) Log output
    RUN_CCS.out.bam.view { meta, bam -> 
        "Completed CCS for sample: ${meta.id} -> ${bam}" 
    }
}