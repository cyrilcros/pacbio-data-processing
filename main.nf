#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
 * PROCESS: Run PacBio CCS + Methylation (Primrose)
 * - Runs CCS with kinetics (Sequel IIe mode)
 * - Immediately runs Primrose to generate MM/ML tags
 * - Outputs a single, rich HiFi BAM
 */
process RUN_CCS_And_METHYLATION {
    tag "$meta.id"
    label 'pacbio_ccs'
    
    // This is your final Archival BAM
    publishDir "${params.outdir}/hifi_bam", mode: 'copy'

    input:
    tuple val(meta), path(subreads_bam), path(subreads_pbi)

    output:
    // Output is HiFi (Q20) + Kinetics + Methylation
    tuple val(meta), path("*.hifi_reads.bam"), path("*.hifi_reads.bam.pbi"), emit: reads

    script:
    def prefix = "${meta.id}"
    """
    # 1. Run CCS 
    # By default, this ONLY outputs reads with rq >= 0.99 (HiFi)
    # We use a temporary name because we are about to pipe it to primrose
    ccs ${subreads_bam} temp.bam \
        -j ${task.cpus} \
        --hifi-kinetics \
        --log-level INFO

    # 2. Run Primrose
    # This reads the kinetics from temp.bam and adds the MM/ML tags
    primrose temp.bam ${prefix}.hifi_reads.bam \
        -j ${task.cpus} \
        -log-level INFO

    # 3. Index the final BAM
    pbindex ${prefix}.hifi_reads.bam

    # 4. Clean up temp
    rm temp.bam temp.bam.pbi
    """
}

workflow {
    ch_subreads = channel.fromPath(params.local_paths_file)
        .splitCsv(header: true)
        .map { row ->
            def meta = [ id: row.sample, run: row.run ]
            def bam_file = file(row.subreads, checkIfExists: true)
            def pbi_file = file("${row.subreads}.pbi", checkIfExists: true)
            return [ meta, bam_file, pbi_file ]
        }

    RUN_CCS_And_METHYLATION(ch_subreads)
}