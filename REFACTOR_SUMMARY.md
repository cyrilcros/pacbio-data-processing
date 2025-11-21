# PacBio Data Processing Pipeline Refactoring Summary

## Changes Completed

### Merged Processes

**Before:** Two separate processes
1. `extract_local_files` - Extracted metadata files only
2. `validate_checksums` - Validated and organized metadata files

**After:** Single merged process
- `extract_and_validate_checksums` - Extracts metadata AND validates ALL checksums

### Key Requirements Implemented

#### ✅ 1. Merge extract_local_files and validate_checksums
- Combined into single `extract_and_validate_checksums` process
- Simplified workflow from 3 steps to 2 steps
- Eliminated intermediate metadata directory channel

#### ✅ 2. Validate ALL checksums (including large BAM files)
- Reads all entries from `.md5` checksum file
- For **large files** (*.subreads.bam, *.subreads.bam.pbi, *.subreadset.xml):
  - Validates checksum WITHOUT extracting
  - Uses `tar -xzf ... -O | md5sum` to stream and compute checksum on-the-fly
  - Keeps files compressed in archive
- For **metadata files** (.xml, .md5):
  - Extracts to working directory
  - Validates checksum
  - Removes leading dot from hidden files

#### ✅ 3. Extract ONLY metadata files (not BAM files)
- BAM files: Validated but kept in archive
- Metadata files: Extracted and validated
  - `${ASSAY_ID}.metadata.xml` (renamed from `.${ASSAY_ID}.metadata.xml`)
  - `${ASSAY_ID}.run.metadata.xml` (renamed from `.${ASSAY_ID}.run.metadata.xml`)
  - `${ASSAY_ID}.sts.xml`
  - `${ASSAY_ID}.md5`

#### ✅ 4. Output: Two channels
1. **metadata channel** - Contains extracted and validated metadata files
   ```groovy
   tuple val(run_id), env(ASSAY_ID), path("*.metadata.xml"), 
         path("*.run.metadata.xml"), path("*.sts.xml"), path("*.md5")
   ```

2. **archive_with_bam channel** - Contains archive + BAM filename for downstream processing
   ```groovy
   tuple val(run_id), env(ASSAY_ID), path(tarball), env(BAM_FILENAME)
   ```

#### ✅ 5. Remove checksum reports from workflow output
- No more `checksum_report.txt` files
- Validation results printed to console only
- Clean output directory with only metadata files and HiFi results

### Workflow Simplification

**Before:**
```groovy
extract_local_files(ch_local_files)
  ↓ (run_id, tarball, metadata_dir, assay_id)
  ↓ map to (meta, tarball, metadata_dir)
validate_checksums(ch_with_meta)
  ↓ subreads channel: (meta, tarball)
extract_hifi_reads(validate_checksums.out.subreads)
```

**After:**
```groovy
extract_and_validate_checksums(ch_local_files)
  ↓ archive_with_bam channel: (run_id, assay_id, tarball, bam_filename)
extract_hifi_reads(extract_and_validate_checksums.out.archive_with_bam)
```

### Technical Implementation Details

#### Checksum Validation Logic

```bash
while IFS= read -r line; do
    EXPECTED_MD5=$(echo "$line" | awk '{print $1}')
    FILE_NAME=$(echo "$line" | awk '{print $2}')
    
    if [[ "$FILE_NAME" == *.subreads.bam ]] || 
       [[ "$FILE_NAME" == *.subreads.bam.pbi ]] || 
       [[ "$FILE_NAME" == *.subreadset.xml ]]; then
        # Large file - validate in archive without extracting
        ACTUAL_MD5=$(tar -xzf "${tarball}" --strip-components=$FOLDER_DEPTH \
                     -O "${DIR_PATH}/${FILE_NAME}" | md5sum | awk '{print $1}')
    else
        # Metadata file - extract and validate
        tar -xzf "${tarball}" --strip-components=$FOLDER_DEPTH "$SOURCE_PATH"
        ACTUAL_MD5=$(md5sum "$FILE_NAME" | awk '{print $1}')
    fi
done < "${ASSAY_ID}.md5"
```

#### Hidden File Handling

```bash
# Handle files with leading dot (e.g., .m54345U_220416_101341.metadata.xml)
if [[ "$FILE_NAME" == .* ]]; then
    SOURCE_PATH="${DIR_PATH}/${FILE_NAME}"
    OUTPUT_NAME="${FILE_NAME#.}"  # Remove leading dot
    mv "$FILE_NAME" "$OUTPUT_NAME"
fi
```

### Output Structure

```
results/
├── metadata/
│   ├── m54345U_220416_101341.metadata.xml
│   ├── m54345U_220416_101341.run.metadata.xml
│   ├── m54345U_220416_101341.sts.xml
│   └── m54345U_220416_101341.md5
└── hifi_reads/
    ├── m54345U_220416_101341.hifi_reads.ccs.bam
    ├── m54345U_220416_101341.ccs.consensusreadset.xml
    ├── m54345U_220416_101341.ccs.log
    ├── m54345U_220416_101341.ccs_reports.json
    └── m54345U_220416_101341.hifi_summary.json
```

### Benefits

1. **Reduced complexity** - One process instead of two
2. **Complete validation** - All files validated including large BAM files
3. **Efficient** - BAM files validated without extraction (saves disk space)
4. **Clean output** - No intermediate checksum reports
5. **Clear separation** - Metadata extracted, BAM files kept in archive
6. **Robust** - Fails early if any checksum validation fails

### Files Modified

- `main.nf` - Complete refactoring
- `main_old.nf` - Backup of previous version

### Testing Recommendations

1. Test with single tar.gz file first
2. Verify all checksums pass validation
3. Check metadata files are extracted correctly
4. Verify HiFi extraction still works with archive
5. Confirm no checksum_report.txt files in output

### Console Output Example

```
Processing r54345U_20220413_154036-3_C03.raw.tar.gz for r54345U_20220413_154036-3_C03...
Input file size: 45G

Detected assay_id: m54345U_220416_101341
BAM filename for extraction: m54345U_220416_101341.subreads.bam

=== Checksum file contents ===
a1b2c3d4e5f6... .m54345U_220416_101341.metadata.xml
1a2b3c4d5e6f... .m54345U_220416_101341.run.metadata.xml
...
f1e2d3c4b5a6... m54345U_220416_101341.subreads.bam
==============================

Validating ALL checksums (including files in archive)...

Extracting and validating: .m54345U_220416_101341.metadata.xml
  ✓ Checksum OK (extracted)
  → Renamed to m54345U_220416_101341.metadata.xml

Extracting and validating: .m54345U_220416_101341.run.metadata.xml
  ✓ Checksum OK (extracted)
  → Renamed to m54345U_220416_101341.run.metadata.xml

Validating (in archive): m54345U_220416_101341.subreads.bam
  ✓ Checksum OK (kept in archive)

SUCCESS: All checksums validated

Verifying required metadata files...
  ✓ m54345U_220416_101341.metadata.xml
  ✓ m54345U_220416_101341.run.metadata.xml
  ✓ m54345U_220416_101341.sts.xml
  ✓ m54345U_220416_101341.md5

Large BAM files remain in archive: r54345U_20220413_154036-3_C03.raw.tar.gz
BAM filename for extraction: m54345U_220416_101341.subreads.bam
```
