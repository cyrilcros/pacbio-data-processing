# Testing Guide for Refactored Pipeline

## Quick Validation

### 1. Syntax Check
```bash
cd /home/user/pacbio-data-processing
nextflow run main.nf --help
```

### 2. Dry Run (if available)
```bash
nextflow run main.nf \
  --local_paths_file paths.txt \
  --outdir results_test \
  -preview
```

### 3. Single File Test
Create a test file with one tarball:
```bash
echo "/scratch/cros/r54345U_20220413_154036-3_C03.raw.tar.gz" > test_single.txt

nextflow run main.nf \
  --local_paths_file test_single.txt \
  --outdir results_single_test
```

## Expected Behavior

### Process: extract_and_validate_checksums

**Inputs:**
- Tarball path (e.g., `r54345U_20220413_154036-3_C03.raw.tar.gz`)

**Actions:**
1. Detect assay_id from first file in archive
2. Extract `.md5` checksum file
3. For EACH file in `.md5`:
   - If BAM file (*.subreads.bam, *.subreads.bam.pbi, *.subreadset.xml):
     * Stream from archive without extracting
     * Compute md5sum on-the-fly
     * Validate against expected checksum
   - If metadata file (.xml, .md5):
     * Extract from archive
     * Compute md5sum
     * Validate against expected checksum
     * Rename if hidden file (remove leading dot)
4. Verify all required metadata files exist
5. Exit with error if any checksum fails

**Outputs:**
- `metadata` channel: (run_id, assay_id, *.metadata.xml, *.run.metadata.xml, *.sts.xml, *.md5)
- `archive_with_bam` channel: (run_id, assay_id, tarball, bam_filename)

**Published files** (to `${params.outdir}/metadata/`):
- `${ASSAY_ID}.metadata.xml`
- `${ASSAY_ID}.run.metadata.xml`
- `${ASSAY_ID}.sts.xml`
- `${ASSAY_ID}.md5`

### Process: extract_hifi_reads

**Inputs:**
- From `archive_with_bam` channel: (run_id, assay_id, tarball, bam_filename)

**Actions:**
1. Extract BAM files from archive:
   - `${assay_id}.subreads.bam`
   - `${assay_id}.subreads.bam.pbi`
   - `${assay_id}.subreadset.xml`
2. Run `ccs` to generate HiFi reads
3. Publish results

**Outputs:**
- HiFi BAM file
- ConsensusReadSet XML
- CCS log
- CCS reports (JSON)

## Validation Checklist

### ✅ Checksum Validation
- [ ] All checksums pass validation
- [ ] Large BAM files validated without extraction
- [ ] Metadata files extracted and validated
- [ ] Hidden files renamed (dot removed)

### ✅ File Extraction
- [ ] Only metadata files extracted (not BAM files)
- [ ] Required metadata files present:
  - [ ] `*.metadata.xml`
  - [ ] `*.run.metadata.xml`
  - [ ] `*.sts.xml`
  - [ ] `*.md5`

### ✅ Output Directory Structure
```
results/
├── metadata/
│   ├── ${ASSAY_ID}.metadata.xml
│   ├── ${ASSAY_ID}.run.metadata.xml
│   ├── ${ASSAY_ID}.sts.xml
│   └── ${ASSAY_ID}.md5
└── hifi_reads/
    ├── ${ASSAY_ID}.hifi_reads.ccs.bam
    ├── ${ASSAY_ID}.ccs.consensusreadset.xml
    ├── ${ASSAY_ID}.ccs.log
    ├── ${ASSAY_ID}.ccs_reports.json
    └── ${ASSAY_ID}.hifi_summary.json
```

### ✅ No Unwanted Files
- [ ] No `checksum_report.txt` files
- [ ] No intermediate metadata directories
- [ ] No extracted BAM files (except in HiFi process work dir)

### ✅ Console Output
Should show:
- Assay ID detection
- Checksum file contents
- Each file validation status with ✓ or ✗
- Clear indication of large files kept in archive
- SUCCESS message after all checksums validated

## Common Issues & Troubleshooting

### Issue: Checksum validation fails
**Symptom:** Process exits with error "Checksum validation failed"
**Cause:** File corruption or incorrect .md5 file
**Solution:** 
1. Check console output to see which file failed
2. Manually verify that file in archive
3. Re-download source data if corrupted

### Issue: Missing metadata files
**Symptom:** Error "Missing required file: ${ASSAY_ID}.xxx.xml"
**Cause:** File not present in archive or incorrect path
**Solution:**
1. List archive contents: `tar -tzf archive.tar.gz | grep -E '\\.xml$|\\.md5$'`
2. Verify file naming matches expected pattern
3. Check FOLDER_DEPTH calculation

### Issue: Cannot extract BAM files in HiFi process
**Symptom:** extract_hifi_reads fails with "file not found"
**Cause:** BAM filename doesn't match archive contents
**Solution:**
1. Check BAM_FILENAME environment variable output
2. List archive: `tar -tzf archive.tar.gz | grep '\\.subreads\\.bam'`
3. Verify naming convention

## Performance Notes

### Memory Usage
- **extract_and_validate_checksums**: Low (only metadata extracted)
  - Validates large files by streaming (minimal memory)
  - Recommended: 4-8 GB

- **extract_hifi_reads**: High (CCS processing)
  - Recommended: 32-64 GB depending on BAM size

### Disk Usage
- Original archive: ~40-50 GB
- Extracted metadata: <1 MB
- Extracted BAM files (in HiFi work dir): ~40-50 GB
- HiFi output: ~10-15 GB

**Total disk space needed per sample:** ~100-120 GB (including work directories)

### Time Estimates
- Checksum validation: 10-20 minutes
  - BAM file validation: ~8-15 minutes (streaming from archive)
  - Metadata extraction: <1 minute
- HiFi extraction: 2-6 hours (depends on coverage)

## Comparison with Previous Version

| Aspect | Before | After |
|--------|--------|-------|
| **Processes** | 2 (extract + validate) | 1 (merged) |
| **Checksum validation** | Metadata only | ALL files (including BAM) |
| **BAM file handling** | Skipped validation | Validated in archive |
| **Checksum reports** | Published to output | Console only |
| **Metadata channel** | Intermediate step | Direct output |
| **Workflow steps** | 3 steps | 2 steps |

## Next Steps After Testing

1. **If single file test passes:**
   ```bash
   # Run full pipeline
   nextflow run main.nf \
     --local_paths_file paths.txt \
     --outdir results \
     -resume
   ```

2. **Monitor execution:**
   ```bash
   # Watch Nextflow logs
   tail -f .nextflow.log
   
   # Check work directory sizes
   du -sh work/*/
   ```

3. **Verify results:**
   ```bash
   # Check metadata output
   ls -lh results/metadata/
   
   # Check HiFi output
   ls -lh results/hifi_reads/
   
   # Verify no checksum reports
   find results -name "checksum_report.txt"  # Should return nothing
   ```

## Rollback Plan

If issues arise, restore previous version:
```bash
cd /home/user/pacbio-data-processing
mv main.nf main_refactored.nf
mv main_old.nf main.nf
```
