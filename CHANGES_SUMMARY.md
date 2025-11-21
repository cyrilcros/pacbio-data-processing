# Pipeline Changes Summary

## Overview
Optimized the PacBio data processing pipeline to:
1. Infer `assay_id` from archive contents automatically
2. Selectively extract only small metadata files
3. Keep large BAM files compressed in the archive
4. Validate checksums during extraction using `tar --to-command`

## Key Changes

### 1. `extract_local_files` Process

**Output Changed:**
- **Before:** `tuple val(run_id), path("data"), env(ASSAY_ID)`
- **After:** `tuple val(run_id), path(tarball), path("metadata"), env(ASSAY_ID)`

**New Features:**
- **Smart assay_id detection**: Lists archive, finds first non-tmp file, extracts assay_id
- **Folder depth detection**: Automatically determines `--strip-components` value
- **Selective extraction**: Only extracts small metadata/XML files
- **On-the-fly validation**: Uses `--to-command` to validate checksums during extraction
- **Keeps archive**: Large BAM files remain in compressed tarball

**Files Extracted to `metadata/`:**
- `${assay_id}.md5` - checksum file
- `.${assay_id}.metadata.xml` - hidden metadata file (with dot)
- `.${assay_id}.run.metadata.xml` - hidden run metadata file (with dot)
- `${assay_id}.sts.xml` - stats file (not hidden)

**Files Kept in Archive:**
- `${assay_id}.subreads.bam` - large BAM file (~GB)
- `${assay_id}.subreads.bam.pbi` - BAM index
- `${assay_id}.subreadset.xml` - BAM dataset XML

### 2. `validate_checksums` Process

**Input Changed:**
- **Before:** `tuple val(meta), path(data_dir)`
- **After:** `tuple val(meta), path(tarball), path(metadata_dir)`

**Output Changed:**
- **Before:** Wildcards `path("data/*.metadata.xml")`, `path("data/*.subreads.bam")`, etc.
- **After:** 
  - `run_metadata`: Explicit paths `path("${meta.assay_id}.metadata.xml")`, etc.
  - `subreads`: Just passes the tarball `path(tarball)`

**New Behavior:**
- Checksums already validated in `extract_local_files`
- This process now just organizes metadata files
- Renames hidden files (removes leading dot for output)
- Passes tarball unchanged to next process

### 3. Workflow Changes

**Channel Mapping:**
```groovy
// Before
extract_local_files.out
    .map { tuple ->
        def (run_id, data_dir, assay_id) = tuple
        def meta = [run_id: run_id, assay_id: assay_id]
        [meta, data_dir]
    }

// After
extract_local_files.out
    .map { tuple ->
        def (run_id, tarball, metadata_dir, assay_id) = tuple
        def meta = [run_id: run_id, assay_id: assay_id]
        [meta, tarball, metadata_dir]
    }
```

### 4. `extract_hifi_reads` Process

**Input Changed:**
- **Before:** `tuple val(meta), path(subreads_bam), path(subreads_pbi), path(subreadset_xml)`
- **After:** `tuple val(meta), path(tarball)`

**Current Implementation:**
- Extracts BAM files from tarball just before CCS processing
- Will be updated later to use CCS streaming mode

## Benefits

### Space Efficiency
- ✅ Don't extract ~10GB BAM files until needed
- ✅ Only extract ~MB metadata files
- ✅ Archive remains compressed

### Performance
- ✅ On-the-fly checksum validation (no re-reading files)
- ✅ Fail-fast on checksum errors
- ✅ Single-pass I/O for metadata

### Correctness
- ✅ Automatic assay_id detection (no hardcoding)
- ✅ Handles hidden files correctly (`.metadata.xml`, `.run.metadata.xml`)
- ✅ Proper file naming for outputs

## Example Flow

```
Input: /g/tier2/.../r54345U_20220413_154036-3_C03.raw.tar.gz (10GB)

1. extract_local_files:
   - List archive → detect assay_id: m54345U_220416_101341
   - Extract .md5 file
   - Stream extract metadata files with validation
   - Skip large .subreads.bam files
   Output: tarball + metadata/ directory

2. validate_checksums:
   - Rename .m54345U_220416_101341.metadata.xml → m54345U_220416_101341.metadata.xml
   - Rename .m54345U_220416_101341.run.metadata.xml → m54345U_220416_101341.run.metadata.xml
   - Copy m54345U_220416_101341.sts.xml
   - Pass tarball to next process
   Output: 3 XML files + tarball

3. extract_hifi_reads:
   - Extract .subreads.bam from tarball just-in-time
   - Run CCS
   Output: HiFi reads
```

## Future Enhancements

- [ ] Implement CCS streaming mode (read directly from tarball)
- [ ] Parallel checksum validation
- [ ] Progress indicators for large files
