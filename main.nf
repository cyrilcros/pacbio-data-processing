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

    // Extract metadata and validate all checksums (one at a time)
    extract_and_validate_checksums(ch_local_files)

    // Extract HiFi reads from validated archives (one at a time)
    extract_hifi_reads(extract_and_validate_checksums.out.archive_with_bam)

    // View HiFi results
    extract_hifi_reads.out.hifi.view { tuple ->
        def (meta, hifi_bam, _consensusreadset) = tuple
        "HIFI: ${meta.run_id} (${meta.assay_id}) -> ${hifi_bam.name}"
    }
}

// --- Processes ---

process extract_and_validate_checksums {
    tag "${run_id}"
    label 'small_job'
    
    input:
    tuple val(run_id), path(tarball)

    output:
    tuple val(run_id), env(ASSAY_ID), path("*.metadata.xml"), path("*.run.metadata.xml"), path("*.sts.xml"), path("*.md5"), emit: metadata
    tuple val(run_id), env(ASSAY_ID), path(tarball), env(BAM_FILENAME), emit: archive_with_bam

    script:
    """
    echo "Processing ${tarball.name} for ${run_id}..."
    echo "Input file size:"
    ls -lh "${tarball}"
    
    # List archive contents and find first non-tmp file to infer assay_id
    echo "Listing archive contents to find assay_id..."
    FIRST_FILE=\$(tar -tzf "${tarball}" | grep -v 'tmp-file' | grep -v 'toarchive.txt' | grep -v '/\$' | head -n 1)
    
    if [ -z "\$FIRST_FILE" ]; then
        echo "ERROR: No valid files found in archive"
        exit 1
    fi
    
    echo "First non-tmp file: \$FIRST_FILE"
    
    # Extract basename and determine folder depth
    BASENAME=\$(basename "\$FIRST_FILE")
    FOLDER_DEPTH=\$(echo "\$FIRST_FILE" | tr -cd '/' | wc -c)
    DIR_PATH=\$(dirname "\$FIRST_FILE")
    
    echo "Basename: \$BASENAME"
    echo "Folder depth: \$FOLDER_DEPTH"
    
    # Remove leading dot if present (for hidden files like .m54345U_220416_101341.run.metadata.xml)
    BASENAME_CLEAN=\${BASENAME#.}
    
    # Extract assay_id (first part before extension/dot)
    export ASSAY_ID=\$(echo "\$BASENAME_CLEAN" | cut -d'.' -f1)
    echo "Detected assay_id: \$ASSAY_ID"
    
    # Extract the BAM filename for downstream processing
    export BAM_FILENAME="\${ASSAY_ID}.subreads.bam"
    echo "BAM filename for extraction: \$BAM_FILENAME"
    
    # Extract .md5 file first
    TARGET_MD5="\${DIR_PATH}/\${ASSAY_ID}.md5"
    echo "Extracting checksum file: \$TARGET_MD5"
    tar -xzf "${tarball}" --strip-components=\$FOLDER_DEPTH "\$TARGET_MD5"
    
    if [ ! -f "\${ASSAY_ID}.md5" ]; then
        echo "ERROR: Could not find \${ASSAY_ID}.md5 in archive"
        exit 1
    fi
    
    echo ""
    echo "=== Checksum file contents ==="
    cat "\${ASSAY_ID}.md5"
    echo "=============================="
    echo ""
    
    # Validate ALL checksums (including large BAM files in archive)
    echo "Validating ALL checksums (including files in archive)..."
    echo ""
    
    VALIDATION_FAILED=0
    
    # Read each line from the .md5 file
    while IFS= read -r line; do
        # Skip empty lines
        [ -z "\$line" ] && continue
        
        # Extract expected checksum and filename
        EXPECTED_MD5=\$(echo "\$line" | awk '{print \$1}')
        FILE_NAME=\$(echo "\$line" | awk '{print \$2}')
        
        # Skip if line doesn't have both checksum and filename
        [ -z "\$EXPECTED_MD5" ] || [ -z "\$FILE_NAME" ] && continue
        
        # Determine if this is a large file (BAM/PBI/XML) or metadata file
        if [[ "\$FILE_NAME" == *.subreads.bam ]] || [[ "\$FILE_NAME" == *.subreads.bam.pbi ]] || [[ "\$FILE_NAME" == *.subreadset.xml ]]; then
            # Large file - validate from archive without extracting
            echo "Validating (in archive): \$FILE_NAME"
            
            # Extract file from archive and compute checksum on-the-fly
            ACTUAL_MD5=\$(tar -xzf "${tarball}" --strip-components=\$FOLDER_DEPTH -O "\${DIR_PATH}/\${FILE_NAME}" | md5sum | awk '{print \$1}')
            
            if [ "\$EXPECTED_MD5" = "\$ACTUAL_MD5" ]; then
                echo "  ✓ Checksum OK (kept in archive)"
            else
                echo "  ✗ Checksum FAILED (expected: \$EXPECTED_MD5, got: \$ACTUAL_MD5)"
                VALIDATION_FAILED=1
            fi
        else
            # Metadata file - extract and validate
            echo "Extracting and validating: \$FILE_NAME"
            
            # Handle hidden files (with dot prefix)
            if [[ "\$FILE_NAME" == .* ]]; then
                SOURCE_PATH="\${DIR_PATH}/\${FILE_NAME}"
                # Remove leading dot for output filename
                OUTPUT_NAME="\${FILE_NAME#.}"
            else
                SOURCE_PATH="\${DIR_PATH}/\${FILE_NAME}"
                OUTPUT_NAME="\${FILE_NAME}"
            fi
            
            # Extract the file
            tar -xzf "${tarball}" --strip-components=\$FOLDER_DEPTH "\$SOURCE_PATH"
            
            if [ -f "\$FILE_NAME" ]; then
                # Compute checksum
                ACTUAL_MD5=\$(md5sum "\$FILE_NAME" | awk '{print \$1}')
                
                if [ "\$EXPECTED_MD5" = "\$ACTUAL_MD5" ]; then
                    echo "  ✓ Checksum OK (extracted)"
                    # Rename to remove dot prefix if needed
                    if [ "\$FILE_NAME" != "\$OUTPUT_NAME" ]; then
                        mv "\$FILE_NAME" "\$OUTPUT_NAME"
                        echo "  → Renamed to \$OUTPUT_NAME"
                    fi
                else
                    echo "  ✗ Checksum FAILED (expected: \$EXPECTED_MD5, got: \$ACTUAL_MD5)"
                    VALIDATION_FAILED=1
                fi
            else
                echo "  ✗ File not found in archive: \$FILE_NAME"
                VALIDATION_FAILED=1
            fi
        fi
        echo ""
    done < "\${ASSAY_ID}.md5"
    
    # Check if validation passed
    if [ \$VALIDATION_FAILED -eq 1 ]; then
        echo "ERROR: Checksum validation failed for one or more files"
        exit 1
    fi
    
    echo "SUCCESS: All checksums validated"
    echo ""
    
    # Verify required metadata files exist
    echo "Verifying required metadata files..."
    
    REQUIRED_FILES=(
        "\${ASSAY_ID}.metadata.xml"
        "\${ASSAY_ID}.run.metadata.xml"
        "\${ASSAY_ID}.sts.xml"
        "\${ASSAY_ID}.md5"
    )
    
    for file in "\${REQUIRED_FILES[@]}"; do
        if [ ! -f "\$file" ]; then
            echo "ERROR: Missing required file: \$file"
            exit 1
        fi
        echo "  ✓ \$file"
    done
    
    echo ""
    echo "Final metadata files:"
    ls -lh *.xml *.md5
    echo ""
    echo "Large BAM files remain in archive: ${tarball}"
    echo "BAM filename for extraction: \$BAM_FILENAME"
    """
}

process extract_hifi_reads {
    tag "${run_id}-${assay_id}"
    label 'pacbio_ccs'
    conda "bioconda::pbccs=6.4.0"
    publishDir "${params.outdir}/hifi_reads", mode: 'copy'
    errorStrategy 'ignore'
    maxForks 1  // Process only one HiFi extraction at a time

    input:
    tuple val(run_id), val(assay_id), path(tarball), val(bam_filename)

    output:
    tuple path("${assay_id}.hifi_reads.ccs.bam"), path("${assay_id}.ccs.consensusreadset.xml"), emit: hifi, optional: true
    tuple path("${assay_id}.ccs.log"), emit: log, optional: true
    tuple path("${assay_id}.ccs_reports.json"), path("${assay_id}.hifi_summary.json"), emit: summary, optional: true

    script:
    """
    echo "Starting CCS for ${assay_id} (${run_id})"
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
        --wildcards "*${assay_id}.subreads.bam" "*${assay_id}.subreads.bam.pbi" "*${assay_id}.subreadset.xml"
    
    echo "Extracted files:"
    ls -lh
    
    echo "Starting HiFi read extraction..."
    ccs \\
        --num-threads ${task.cpus} \\
        --min-passes 3 \\
        --min-rq 0.99 \\
        --log-level INFO \\
        --log-file ${assay_id}.ccs.log \\
        --report-json ${assay_id}.ccs_reports.json \\
        --hifi-summary-json ${assay_id}.hifi_summary.json \\
        ${assay_id}.subreads.bam \\
        ${assay_id}.hifi_reads.ccs.bam
    
    echo "HiFi extraction completed for ${assay_id}"
    """
}
