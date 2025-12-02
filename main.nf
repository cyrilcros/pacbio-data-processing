#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

/*
 * PROCESS 1: Run CCS (Genomic)
 * - Generates HiFi reads
 * - PRESERVES KINETICS (--hifi-kinetics)
 * - Saves this intermediate file to disk
 */
process RUN_CCS_GENOMIC {
    tag "$meta.id"
    label 'pacbio_ccs'

    input:
    tuple val(meta), path(subreads), path(pbi)

    output:
    // This is the input for the next step
    tuple val(meta), path("*.hifi_kinetics.bam"), path("*.hifi_kinetics.bam.pbi"), emit: bam

    script:
    def prefix = "${meta.id}"
    """
    # Run CCS with kinetics
    # We explicitly name it *.hifi_kinetics.bam to distinguish it
    ccs ${subreads} ${prefix}.hifi_kinetics.bam \
        -j ${task.cpus} \
        --hifi-kinetics \
        --log-level INFO
    """
}

/*
 * PROCESS 2: Run Jasmine (Methylation)
 * - Takes the Kinetics BAM from Step 1
 * - Adds MM/ML tags
 * - Uses --keep-kinetics to ensure pw/ip tags are not stripped
 */
process RUN_JASMINE {
    tag "$meta.id"
    label 'pacbio_ccs' // Re-using the large node config, or you can define a smaller one
    
    // Save the final BAM (HiFi + Kinetics + Methylation)
    publishDir "${params.outdir}/final_genomic_bam", mode: 'copy'

    input:
    tuple val(meta), path(kinetics_bam), path(kinetics_pbi)

    output:
    tuple val(meta), path("*.hifi_reads.bam"), path("*.hifi_reads.bam.pbi"), emit: reads

    script:
    def prefix = "${meta.id}"
    """
    # Run Jasmine
    # Input:  The output from CCS
    # Output: Final BAM with 5mC calls
    # Flag:   --keep-kinetics (Preserves pw/ip tags)
    
    jasmine ${kinetics_bam} ${prefix}.hifi_reads.bam \
        --num-threads ${task.cpus} \
        --keep-kinetics \
        --log-level INFO

    # Index the final BAM
    pbindex ${prefix}.hifi_reads.bam
    """
}

/*
 * PROCESS 3-5: Iso-Seq Processes (Same as before)
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
    ccs ${subreads} ${prefix}.hifi.bam -j ${task.cpus} --min-rq 0.9
    """
}

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
    # 1. Create Primer Files
    echo ">NEB_5p" > primers_neb.fasta
    echo "GCAATGAAGTCGCAGGGTTGGG" >> primers_neb.fasta
    echo ">NEB_3p" >> primers_neb.fasta
    echo "GTACTCTGCGTTGATACCACTGCTT" >> primers_neb.fasta

    echo ">Clontech_5p" > primers_clontech.fasta
    echo "AAGCAGTGGTATCAACGCAGAGTACATGGGG" >> primers_clontech.fasta
    echo ">Clontech_3p" >> primers_clontech.fasta
    echo "AAGCAGTGGTATCAACGCAGAGTAC" >> primers_clontech.fasta

    # 2. Run Lima Twice
    lima ${bam} primers_neb.fasta ${prefix}.neb.bam \
        --isoseq --peek-guess --num-threads ${task.cpus} || true

    lima ${bam} primers_clontech.fasta ${prefix}.clontech.bam \
        --isoseq --peek-guess --num-threads ${task.cpus} || true

    # 3. Dynamic Selection
    TARGET_BAM=\$(ls -S ${prefix}.*.*p--*p.bam 2>/dev/null | head -n 1)

    if [ -z "\$TARGET_BAM" ]; then
        echo "FATAL: No valid reads found."
        exit 1
    fi

    # Pick correct primer file for Refine step
    if [[ "\$TARGET_BAM" == *".neb."* ]]; then
        FINAL_PRIMERS="primers_neb.fasta"
    else
        FINAL_PRIMERS="primers_clontech.fasta"
    fi

    # 4. Refine
    isoseq3 refine \$TARGET_BAM \$FINAL_PRIMERS ${prefix}.flnc.bam \
        --require-polya --num-threads ${task.cpus}

    # 5. Cluster
    isoseq3 cluster ${prefix}.flnc.bam ${prefix}.clustered.bam \
        --verbose --use-qvs --num-threads ${task.cpus}

    # 6. Convert to FASTA (Replaces Polish)
    # The clustered BAM contains the high-quality transcripts.
    bam2fasta -o ${prefix}.hq ${prefix}.clustered.bam -c 0

    """
}

/*
 * WORKFLOW
 */
workflow {
    ch_inputs = channel.fromPath(params.local_paths_file)
        .splitCsv(header: true)
        .map { row ->
            def meta = [ id: row.sample, run: row.run, type: row.type ]
            def bam = file(row.subreads, checkIfExists: true)
            def pbi = file("${row.subreads}.pbi", checkIfExists: true)
            return [ meta, bam, pbi ]
        }

    // Branch into Genomic vs IsoSeq
    ch_inputs.branch { it ->
        genomic: it[0].type == 'genomic'
        isoseq:  it[0].type == 'isoseq'
    }.set { ch_branched }

    // GENOMIC PIPELINE (Split)
    // Step 1: CCS (produces kinetics BAM)
    RUN_CCS_GENOMIC(ch_branched.genomic)
    
    // Step 2: Jasmine (produces methylation BAM, keeps kinetics)
    RUN_JASMINE(RUN_CCS_GENOMIC.out.bam)

    // ISOSEQ PIPELINE
    CCS_FOR_ISOSEQ(ch_branched.isoseq)
    RUN_ISOSEQ_PIPELINE(CCS_FOR_ISOSEQ.out.hifi)
}