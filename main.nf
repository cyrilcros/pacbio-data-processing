#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
 * PROCESS 1: Genomic DNA (gDNA) with Jasmine
 * - Runs CCS with kinetics (Sequel IIe/Revio mode)
 * - Runs Jasmine to generate MM/ML methylation tags
 * - Outputs a single, rich HiFi BAM
 */
process PROCESS_GENOMIC {
    tag "$meta.id"
    label 'pacbio_ccs'
    
    // Save the rich BAM
    publishDir "${params.outdir}/genomic_bam", mode: 'copy'

    input:
    tuple val(meta), path(subreads), path(pbi)

    output:
    // Output contains Sequence + Quality + Kinetics + Methylation (MM/ML)
    tuple val(meta), path("*.hifi_reads.bam"), path("*.hifi_reads.bam.pbi"), emit: reads

    script:
    def prefix = "${meta.id}"
    """
    # 1. Run CCS with kinetics preserved
    # We output to a temp file because Jasmine will create the final BAM
    ccs ${subreads} temp.kinetics.bam \
        -j ${task.cpus} \
        --hifi-kinetics \
        --log-level INFO

    # 2. Run Jasmine (Replaces Primrose)
    # Reads kinetics from temp.bam and writes final BAM with MM/ML tags
    jasmine temp.kinetics.bam ${prefix}.hifi_reads.bam \
        --num-threads ${task.cpus} \
        --log-level INFO

    # 3. Index the final BAM
    pbindex ${prefix}.hifi_reads.bam

    # 4. Clean up temp
    rm temp.kinetics.bam temp.kinetics.bam.pbi
    """
}

/*
 * PROCESS 2: CCS for Iso-Seq
 */
process CCS_FOR_ISOSEQ {
    tag "$meta.id"
    label 'pacbio_ccs' 
    publishDir "${params.outdir}/isoseq_intermediate_hifi", mode: 'copy'

    input:
    tuple val(meta), path(subreads), path(pbi)

    output:
    tuple val(meta), path("*.hifi.bam"), path("*.hifi.bam.pbi"), emit: hifi

    script:
    def prefix = "${meta.id}"
    """
    # Standard CCS for Iso-Seq (min rq 0.9)
    ccs ${subreads} ${prefix}.hifi.bam \
        -j ${task.cpus} \
        --min-rq 0.9
    """
}

/*
 * PROCESS 3: Run Iso-Seq Pipeline (Step 2)
 * Lima -> Refine -> Cluster
 * Uses the NEW label 'pacbio_isoseq'
 */
process RUN_ISOSEQ_PIPELINE {
    tag "$meta.id"
    label 'pacbio_isoseq'
    publishDir "${params.outdir}/isoseq_transcripts", mode: 'copy'

    input:
    tuple val(meta), path(bam), path(pbi)

    output:
    tuple val(meta), path("*.hq.fasta.gz"), emit: fasta
    tuple val(meta), path("*.hq.bam"),      emit: bam
    tuple val(meta), path("*.lq.fasta.gz"), optional: true

    script:
    def prefix = "${meta.id}"
    """
    # 1. Create Combined Primer File
    echo ">NEB_5p" > primers.fasta
    echo "GCAATGAAGTCGCAGGGTTGGG" >> primers.fasta
    echo ">NEB_3p" >> primers.fasta
    echo "GTACTCTGCGTTGATACCACTGCTT" >> primers.fasta
    echo ">Clontech_5p" >> primers.fasta
    echo "AAGCAGTGGTATCAACGCAGAGTACATGGGG" >> primers.fasta
    echo ">Clontech_3p" >> primers.fasta
    echo "AAGCAGTGGTATCAACGCAGAGTAC" >> primers.fasta

    # 2. Lima (Demultiplexing)
    # This will create files like: ${prefix}.fl.NEB_5p--NEB_3p.bam
    lima ${bam} primers.fasta ${prefix}.fl.bam \
        --isoseq --peek-guess --num-threads ${task.cpus}

    # 3. Dynamic Selection
    # Find the BAM file that lima actually produced (The one with the most reads)
    # This automatically picks NEB or Clontech without us needing to know.
    TARGET_BAM=\$(ls -S ${prefix}.fl.*--*.bam 2>/dev/null | head -n 1)

    if [ -z "\$TARGET_BAM" ]; then
        echo "ERROR: Lima found no primers. Check your data!"
        exit 1
    fi

    echo "Detected Primer Pair: \$TARGET_BAM"

    # 4. Refine (PolyA Trim)
    isoseq3 refine \$TARGET_BAM primers.fasta ${prefix}.flnc.bam \
        --require-polya --num-threads ${task.cpus}

    # 5. Cluster
    isoseq3 cluster ${prefix}.flnc.bam ${prefix}.clustered.bam \
        --verbose --use-qvs --num-threads ${task.cpus}

    # 6. Polish (High Quality Output)
    isoseq3 polish ${prefix}.clustered.bam ${prefix}.polished.bam \
        --verbose --num-threads ${task.cpus}
    """
}

workflow {
    ch_inputs = channel.fromPath(params.local_paths_file)
        .splitCsv(header: true)
        .map { row ->
            def meta = [ id: row.sample, run: row.run, type: row.type ]
            def bam = file(row.subreads, checkIfExists: true)
            def pbi = file("${row.subreads}.pbi", checkIfExists: true)
            return [ meta, bam, pbi ]
        }

    ch_inputs.branch {
        genomic: it[0].type == 'genomic'
        isoseq:  it[0].type == 'isoseq'
    }.set { ch_branched }

    PROCESS_GENOMIC(ch_branched.genomic)
    CCS_FOR_ISOSEQ(ch_branched.isoseq)
    RUN_ISOSEQ_PIPELINE(CCS_FOR_ISOSEQ.out.hifi)
}