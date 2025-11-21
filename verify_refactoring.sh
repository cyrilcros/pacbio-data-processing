#!/bin/bash

# Verification script for PacBio pipeline refactoring
# This script checks that all changes are correctly implemented

set -e

echo "============================================"
echo "PacBio Pipeline Refactoring Verification"
echo "============================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SUCCESS=0
FAILURES=0

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((SUCCESS++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAILURES++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo "1. Checking file structure..."
echo "================================"

# Check main files exist
if [ -f "main.nf" ]; then
    check_pass "main.nf exists"
else
    check_fail "main.nf missing"
fi

if [ -f "main_old.nf" ]; then
    check_pass "main_old.nf backup exists"
else
    check_warn "main_old.nf backup not found (may not be needed)"
fi

echo ""
echo "2. Checking process definitions..."
echo "================================"

# Check for merged process
if grep -q "process extract_and_validate_checksums" main.nf; then
    check_pass "Found extract_and_validate_checksums process"
else
    check_fail "extract_and_validate_checksums process not found"
fi

# Check old processes are removed
if grep -q "process extract_local_files" main.nf; then
    check_fail "Old extract_local_files process still present"
else
    check_pass "Old extract_local_files process removed"
fi

if grep -q "process validate_checksums {" main.nf; then
    check_fail "Old validate_checksums process still present"
else
    check_pass "Old validate_checksums process removed"
fi

# Check HiFi process exists
if grep -q "process extract_hifi_reads" main.nf; then
    check_pass "extract_hifi_reads process exists"
else
    check_fail "extract_hifi_reads process missing"
fi

echo ""
echo "3. Checking checksum validation logic..."
echo "========================================"

# Check for BAM file validation (in archive)
if grep -q "tar -xzf.*-O.*md5sum" main.nf; then
    check_pass "BAM file validation (streaming) implemented"
else
    check_fail "BAM file validation not found"
fi

# Check for metadata file extraction
if grep -q "tar -xzf.*--strip-components" main.nf; then
    check_pass "Metadata extraction logic present"
else
    check_fail "Metadata extraction not found"
fi

# Check for hidden file handling
if grep -q 'FILE_NAME#\.' main.nf || grep -q 'OUTPUT_NAME.*FILE_NAME#' main.nf; then
    check_pass "Hidden file renaming logic present"
else
    check_warn "Hidden file renaming may not be implemented"
fi

echo ""
echo "4. Checking output channels..."
echo "=============================="

# Check for metadata output channel
if grep -q "emit: metadata" main.nf; then
    check_pass "metadata output channel defined"
else
    check_fail "metadata output channel missing"
fi

# Check for archive_with_bam output channel
if grep -q "emit: archive_with_bam" main.nf; then
    check_pass "archive_with_bam output channel defined"
else
    check_fail "archive_with_bam output channel missing"
fi

echo ""
echo "5. Checking for removed features..."
echo "==================================="

# Check that checksum_report.txt is not generated
if grep -q "checksum_report.txt" main.nf; then
    check_warn "checksum_report.txt still referenced (should be removed)"
else
    check_pass "checksum_report.txt references removed"
fi

# Check publishDir for metadata
if grep -q 'publishDir.*metadata' main.nf; then
    check_pass "publishDir configured for metadata"
else
    check_fail "publishDir not configured for metadata"
fi

echo ""
echo "6. Checking workflow structure..."
echo "================================="

# Check workflow calls merged process
if grep -q "extract_and_validate_checksums(ch_local_files)" main.nf; then
    check_pass "Workflow calls extract_and_validate_checksums"
else
    check_fail "Workflow doesn't call extract_and_validate_checksums"
fi

# Check workflow calls HiFi process with correct channel
if grep -q "extract_hifi_reads(extract_and_validate_checksums.out.archive_with_bam)" main.nf; then
    check_pass "Workflow correctly connects to HiFi process"
else
    check_fail "Workflow connection to HiFi process incorrect"
fi

echo ""
echo "7. Syntax validation..."
echo "======================="

# Try to validate Nextflow syntax (if nextflow is available)
if command -v nextflow &> /dev/null; then
    if nextflow config -check main.nf &> /dev/null; then
        check_pass "Nextflow syntax validation passed"
    else
        check_fail "Nextflow syntax validation failed"
        echo "    Run 'nextflow config -check main.nf' for details"
    fi
else
    check_warn "Nextflow not available for syntax checking"
fi

echo ""
echo "8. Checking documentation..."
echo "============================"

if [ -f "REFACTOR_SUMMARY.md" ]; then
    check_pass "REFACTOR_SUMMARY.md exists"
else
    check_warn "REFACTOR_SUMMARY.md not found"
fi

if [ -f "TESTING_GUIDE.md" ]; then
    check_pass "TESTING_GUIDE.md exists"
else
    check_warn "TESTING_GUIDE.md not found"
fi

if [ -f "REFACTORING_COMPLETE.md" ]; then
    check_pass "REFACTORING_COMPLETE.md exists"
else
    check_warn "REFACTORING_COMPLETE.md not found"
fi

echo ""
echo "============================================"
echo "Verification Summary"
echo "============================================"
echo -e "${GREEN}Passed: $SUCCESS${NC}"
if [ $FAILURES -gt 0 ]; then
    echo -e "${RED}Failed: $FAILURES${NC}"
    echo ""
    echo "Please review the failures above and fix them before running the pipeline."
    exit 1
else
    echo -e "${RED}Failed: $FAILURES${NC}"
    echo ""
    echo -e "${GREEN}✓ All critical checks passed!${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Review TESTING_GUIDE.md for testing procedures"
    echo "2. Test with a single file first"
    echo "3. Verify output structure and checksums"
    echo "4. Run full pipeline with all samples"
    exit 0
fi
