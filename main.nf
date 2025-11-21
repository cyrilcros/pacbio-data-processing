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
            def (run_id, tarball, metadata_dir, assay_id) = tuple
            def meta = [run_id: run_id, assay_id: assay_id]
            [meta, tarball, metadata_dir]
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
    tuple val(run_id), path(tarball), path("metadata"), env(ASSAY_ID)

    script:
    """
    echo "Processing ${tarball.name} for ${run_id}..."
    
    echo "Input file size:"
    ls -lh "${tarball}"
    
    # List archive contents and find first non-tmp file to infer assay_id
    echo "Listing archive contents to find assay_id..."
    FIRST_FILE=\$(tar -tzf "${tarball}" | grep -v 'tmp-file' | grep -v '/\$' | head -n 1)
    
    if [ -z "\$FIRST_FILE" ]; then
        echo "ERROR: No valid files found in archive"
        exit 1
    fi
    
    echo "First non-tmp file: \$FIRST_FILE"
    
    # Extract basename and determine folder depth
    BASENAME=\$(basename "\$FIRST_FILE")
    FOLDER_DEPTH=\$(echo "\$FIRST_FILE" | tr -cd '/' | wc -c)
    
    echo "Basename: \$BASENAME"
    echo "Folder depth: \$FOLDER_DEPTH"
    
    # Remove leading dot if present (for hidden files like .m54345U_220416_101341.run.metadata.xml)
    BASENAME_CLEAN=\${BASENAME#.}
    
    # Extract assay_id (first part before extension/dot)
    export ASSAY_ID=\$(echo "\$BASENAME_CLEAN" | cut -d'.' -f1)
    echo "Detected assay_id: \$ASSAY_ID"
    
    # Create metadata directory
    mkdir -p metadata
    
    # Extract only small metadata/XML files, NOT the large BAM files
    # Extract and validate checksums on-the-fly using --to-command
    echo "Extracting metadata files with checksum validation..."
    
    # First extract the .md5 file
    tar -xzf "${tarball}" --wildcards "*\${ASSAY_ID}.md5" --strip-components=\$FOLDER_DEPTH -C metadata/
    
    if [ ! -f "metadata/\${ASSAY_ID}.md5" ]; then
        echo "ERROR: Could not find \${ASSAY_ID}.md5 in archive"
        exit 1
    fi
    
    echo "Contents of \${ASSAY_ID}.md5:"
    cat "metadata/\${ASSAY_ID}.md5"
    
    # Create checksum validation script for metadata files
    cat > validate_metadata.sh <<'SCRIPT'
#!/bin/bash
FILE_PATH="\$TAR_REALNAME"
FILE_NAME=\$(basename "\$FILE_PATH")

# Skip large BAM files - we keep those in the archive
if [[ "\$FILE_NAME" == *.subreads.bam ]] || [[ "\$FILE_NAME" == *.subreads.bam.pbi ]] || [[ "\$FILE_NAME" == *.subreadset.xml ]]; then
    echo "⊘ \$FILE_NAME: skipped (large file, kept in archive)"
    exit 0
fi

# Skip directories
if [ -d "\$FILE_PATH" ]; then
    exit 0
fi

# Save stdin to file in metadata directory
cat > "metadata/\$FILE_NAME"

# Validate checksum
EXPECTED_MD5=\$(grep "\$FILE_NAME" "metadata/\${ASSAY_ID}.md5" 2>/dev/null | awk '{print \$1}')

if [ -n "\$EXPECTED_MD5" ]; then
    ACTUAL_MD5=\$(md5sum "metadata/\$FILE_NAME" | awk '{print \$1}')
    if [ "\$EXPECTED_MD5" = "\$ACTUAL_MD5" ]; then
        echo "✓ \$FILE_NAME: checksum OK"
    else
        echo "✗ \$FILE_NAME: checksum FAILED (expected: \$EXPECTED_MD5, got: \$ACTUAL_MD5)"
        exit 1
    fi
fi
SCRIPT
    
    chmod +x validate_metadata.sh
    
    # Stream extract metadata files with validation
    tar -xzf "${tarball}" --strip-components=\$FOLDER_DEPTH --to-command='./validate_metadata.sh' 2>&1 | grep -E '^(✓|✗|⊘)'
    
    echo ""
    echo "Metadata extraction completed. Files:"
    ls -la metadata/
    
    echo "Final assay_id: \$ASSAY_ID"
    echo "Large BAM files remain compressed in: ${tarball}"
    """
}

process validate_checksums {
    tag "${meta.run_id}"
    errorStrategy 'ignore'

    input:
    tuple val(meta), path(tarball), path(metadata_dir)

    output:
    tuple val(meta), path("${meta.assay_id}.metadata.xml"), path("${meta.assay_id}.run.metadata.xml"), path("${meta.assay_id}.sts.xml"), path("checksum_report.txt"), emit: run_metadata
    tuple val(meta), path(tarball), emit: subreads

    script:
    """
    # Checksums were already validated during extraction
    # This process organizes the metadata files with proper naming
    
    echo "Organizing files for ${meta.assay_id}..." > checksum_report.txt
    echo "Checksums were validated during extraction" >> checksum_report.txt
    echo "" >> checksum_report.txt
    
    # The hidden files in metadata_dir need to have the dot prefix for these two:
    # .${meta.assay_id}.metadata.xml -> ${meta.assay_id}.metadata.xml
    # .${meta.assay_id}.run.metadata.xml -> ${meta.assay_id}.run.metadata.xml
    
    # Copy metadata.xml (hidden file with dot)
    if [ -f "${metadata_dir}/.${meta.assay_id}.metadata.xml" ]; then
        cp "${metadata_dir}/.${meta.assay_id}.metadata.xml" "${meta.assay_id}.metadata.xml"
        echo "✓ Found and renamed .${meta.assay_id}.metadata.xml" >> checksum_report.txt
    else
        echo "ERROR: Missing .${meta.assay_id}.metadata.xml" >> checksum_report.txt
        exit 1
    fi
    
    # Copy run.metadata.xml (hidden file with dot)
    if [ -f "${metadata_dir}/.${meta.assay_id}.run.metadata.xml" ]; then
        cp "${metadata_dir}/.${meta.assay_id}.run.metadata.xml" "${meta.assay_id}.run.metadata.xml"
        echo "✓ Found and renamed .${meta.assay_id}.run.metadata.xml" >> checksum_report.txt
    else
        echo "ERROR: Missing .${meta.assay_id}.run.metadata.xml" >> checksum_report.txt
        exit 1
    fi
    
    # Copy sts.xml (not hidden)
    if [ -f "${metadata_dir}/${meta.assay_id}.sts.xml" ]; then
        cp "${metadata_dir}/${meta.assay_id}.sts.xml" "${meta.assay_id}.sts.xml"
        echo "✓ Found ${meta.assay_id}.sts.xml" >> checksum_report.txt
    else
        echo "ERROR: Missing ${meta.assay_id}.sts.xml" >> checksum_report.txt
        exit 1
    fi
    
    echo "" >> checksum_report.txt
    echo "SUCCESS: All metadata files organized for ${meta.assay_id}" >> checksum_report.txt
    echo "Large files (.subreads.bam, .subreads.bam.pbi, .subreadset.xml) remain in archive: ${tarball}" >> checksum_report.txt
    
    ls -lh >> checksum_report.txt
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
    tuple val(meta), path(tarball)

    output:
    tuple val(meta), path("${meta.assay_id}.hifi_reads.ccs.bam"), path("${meta.assay_id}.ccs.consensusreadset.xml"), emit: hifi, optional: true
    tuple val(meta), path("${meta.assay_id}.ccs.log"), emit: log, optional: true
    tuple val(meta), path("${meta.assay_id}.ccs_reports.json"), path("${meta.assay_id}.hifi_summary.json"), emit: summary, optional: true

    script:
    """
    echo "Starting CCS for ${meta.assay_id} (${meta.run_id})"
    echo "Archive size:"
    ls -lh ${tarball}
    
    # List archive contents to determine folder depth
    FIRST_FILE=\$(tar -tzf "${tarball}" | grep -v 'tmp-file' | grep -v '/\$' | head -n 1)
    FOLDER_DEPTH=\$(echo "\$FIRST_FILE" | tr -cd '/' | wc -c)
    
    echo "Detected folder depth: \$FOLDER_DEPTH"
    
    # Extract only the large BAM files needed for CCS
    echo "Extracting subreads BAM files from archive..."
    tar -xzf "${tarball}" \\
        --strip-components=\$FOLDER_DEPTH \\
        --wildcards "*${meta.assay_id}.subreads.bam" "*${meta.assay_id}.subreads.bam.pbi" "*${meta.assay_id}.subreadset.xml"
    
    echo "Extracted files:"
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
        ${meta.assay_id}.subreads.bam \\
        ${meta.assay_id}.hifi_reads.ccs.bam
    
    echo "HiFi extraction completed for ${meta.assay_id}"
    """
}