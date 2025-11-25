#!/usr/bin/env nextflow

/*
 * PacBio CCS Processing Workflow
 * Based on provided TSV input and Slurm configuration
 */

nextflow.enable.dsl = 2

/*
 * PROCESS: Run PacBio CCS
 * Uses label 'pacbio_ccs' to map to the 64 CPU / 128 GB RAM / Conda config
 * Updates:
 * - Uses --all to keep all reads (Full BAM)
 * - Emits consolidated 'reads' channel and 'logs' channel
 */
process RUN_CCS {
    tag "$meta.id"
    label 'pacbio_ccs'
    
    // Output results to the directory specified in params.yml
    publishDir "${params.outdir}/ccs_all_bam", mode: 'copy'

    input:
    tuple val(meta), path(subreads_bam), path(subreads_pbi)

    output:
    // Combined reads channel as requested
    tuple val(meta), path("*.all.bam"), path("*.all.bam.pbi"), emit: reads
    // Combined logs channel
    tuple val(meta), path("*.report.txt"), path("*.json"),     emit: logs

    script:
    def prefix = "${meta.id}"
    """
    # Run CCS with --all to generate Full BAM (all consensus reads)
    ccs ${subreads_bam} ${prefix}.all.bam \
        --threads ${task.cpus} \
        --all \
        --report-file ${prefix}.ccs_report.txt \
        --report-json ${prefix}.ccs_report.json \
        --log-level INFO
    """
}

/*
 * PROCESS: Filter HiFi Reads
 * Extracts reads with Read Quality (rq) >= 0.99 (Q20)
 * Generates .pbi index for the new BAM
 * Updates:
 * - Uses bamtools as requested
 */
process FILTER_HIFI {
    tag "$meta.id"
    label 'small_job' // Uses the 4 CPU config
    
    // Need bamtools for filtering and pbtk for pbindex
    conda "bioconda::bamtools bioconda::pbtk"
    
    publishDir "${params.outdir}/ccs_hifi_bam", mode: 'copy'

    input:
    tuple val(meta), path(bam), path(pbi)

    output:
    tuple val(meta), path("*.hifi.bam"), path("*.hifi.bam.pbi"), emit: reads

    script:
    def prefix = "${meta.id}"
    """
    # Filter for HiFi reads (rq >= 0.99) using bamtools
    bamtools filter \\
        -in ${bam} \\
        -out ${prefix}.hifi.bam \\
        -tag "rq":">=0.99"

    # Generate PBI index for the filtered BAM
    pbindex ${prefix}.hifi.bam
    """
}

/*
 * WORKFLOW
 */
workflow {

    // 1. Create Channel from TSV
    ch_subreads = channel.fromPath(params.local_paths_file)
        .splitCsv(header: true)
        .view {it -> it}
        .map { row ->
            def meta = [
                id: row.sample,
                run: row.run
            ]
            def bam_file = file(row.subreads, checkIfExists: true)
            def pbi_file = file("${row.subreads}.pbi", checkIfExists: true)
            
            return [ meta, bam_file, pbi_file ]
        }

    // 2. Run CCS to get Full BAM
    RUN_CCS(ch_subreads)

    // 3. Filter for HiFi reads
    FILTER_HIFI(RUN_CCS.out.reads)

    // 4. (Optional) Log output
    FILTER_HIFI.out.reads.view { meta, bam, pbi -> 
        "Generated HiFi BAM for: ${meta.id} -> ${bam}" 
    }
}