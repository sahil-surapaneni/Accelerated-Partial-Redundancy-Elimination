#!/bin/bash

# help output for program
help()
{
    # Display Help
    echo "Helper script to compile a single program using different combinations of LLVM passes and output statistics."
    echo
    echo "Syntax: get_statistics [-h] [-d] source_program [pass_string]"
    echo "options:"
    echo "   - h     Print this help."
    echo "   - d     Delete intermediate files (but not compiled executable files)"
    echo "   - D     Delete all produced files"
    echo "argument:"
    echo "   - source_program    A single .c file to compile and run stats on"
    echo "                       ** Note: omit the .c extension, i.e. \"example.c\" should just be \"example\"" 
    echo "   - pass_string       If set, a string (in double quotes) indicating the pass(es) to run."
    echo "                       ** Defaults to \"-ispre\""
    echo "                       ** Example: \"-ispre -anotherpass\""
}

# helper function to allow for piping input
get_bytes_from_bcanalysis () {
    echo "$1" | sed -n '2p' - | tr '\n' ' ' | sed -e 's/[^0-9]/ /g' -e 's/^ *//g' -e 's/ *$//g' | tr -s ' ' | sed 's/ /\n/g' | sed -n '2p' -  
}

delete_intermediate=0
delete_all=0
# Get command line options
while getopts ":hdD" option; do
    case $option in
        h) # display help
            help
            exit;;
        d) # delete executables
            delete_intermediate=1;;
        D) # delete all
            delete_all=1;;
        \?) # incorrect option
            echo "Error: Invalid option"
            exit 1;;
    esac
done
# Shift cli arguments to ignore options
shift "$((OPTIND-1))"

# Verify at least one argument (source program) was passed
if [ "$#" -lt 1 ] 
then
    echo "*** Missing argument ***"
    echo ""
    help
    exit 1
fi

# Get command line arguments
source_program=${1}
passes=${2:-"-ispre"}
multipasses="--ispre --ispre2 --ispre3 --ispre4"
llvm_library="../build/ISPRE/ISPRE.so"

# Delete outputs from any previous runs
rm -f default.profraw ${source_program}_prof ${source_program}_ispre ${source_program}_multiispre ${source_program}_no_ispre ${source_program}_gvn *.bc ${source_program}.profdata *_output *.ll

# Convert source code to bitcode (IR)
clang -emit-llvm -Xclang -disable-O0-optnone -c ${source_program}.c -o ${source_program}.bc
# Instrument profiler
opt -enable-new-pm=0 -pgo-instr-gen -instrprof ${source_program}.bc -o ${source_program}.prof.bc
# Generate binary executable with profiler embedded
clang -fprofile-instr-generate ${source_program}.prof.bc -o ${source_program}_prof

# Generate profiled data
./${source_program}_prof > correct_output
llvm-profdata merge -o ${source_program}.profdata default.profraw

# Use opt three times to compile with specific passes
opt -enable-new-pm=0 -o ${source_program}.none.bc -pgo-instr-use -pgo-test-profile-file=${1}.profdata < ${source_program}.bc > /dev/null
opt -enable-new-pm=0 -o ${source_program}.gvn.bc -pgo-instr-use -pgo-test-profile-file=${1}.profdata -gvn -dce < ${source_program}.bc > /dev/null
opt -enable-new-pm=0 -o ${source_program}.ispre.bc -pgo-instr-use -pgo-test-profile-file=${1}.profdata -load ${llvm_library} ${passes} -dce < ${source_program}.bc > /dev/null
opt -enable-new-pm=0 -o ${source_program}.multiispre.bc -pgo-instr-use -pgo-test-profile-file=${1}.profdata -load ${llvm_library} ${multipasses} -dce < ${source_program}.bc > /dev/null

# Generate binary excutable before ISPRE: Unoptimized code
clang ${source_program}.none.bc -o ${source_program}_no_ispre
# Generate binary excutable after GVN: Optimized code
clang ${source_program}.gvn.bc -o ${source_program}_gvn
# Generate binary executable after ISPRE: Our optimized code
clang ${source_program}.ispre.bc -o ${source_program}_ispre
# Generate binary executable after Multipass ISPRE: Our optimized code
clang ${source_program}.multiispre.bc -o ${source_program}_multiispre

# Produce output from binary to check correctness
./${source_program}_ispre > ispre_output
./${source_program}_multiispre > multiispre_output

echo -e "=== Correctness Check ==="
echo ">> Does the custom pass maintain correct program behavior?"
if [ "$(diff correct_output ispre_output)" != "" ]; then
    echo -e ">> FAIL - Single Pass\n"
elif [ "$(diff correct_output multiispre_output)" != "" ]; then
    echo -e ">> FAIL - Multi Pass\n"
else
    echo -e ">> PASS\n"

    bcanalyzer_unoptimized="llvm-bcanalyzer ${source_program}.none.bc"
    bcanalysis_unoptimized="$($bcanalyzer_unoptimized)"
    bytes_unoptimized=$(get_bytes_from_bcanalysis "${bcanalysis_unoptimized}")

    bcanalyzer_gvn_optimized="llvm-bcanalyzer ${source_program}.gvn.bc"
    bcanalysis_gvn_optimized="$($bcanalyzer_gvn_optimized)"
    bytes_gvn_optimized=$(get_bytes_from_bcanalysis "${bcanalysis_gvn_optimized}")

    bcanalyzer_optimized="llvm-bcanalyzer ${source_program}.ispre.bc"
    bcanalysis_optimized="$($bcanalyzer_optimized)"
    bytes_optimized=$(get_bytes_from_bcanalysis "${bcanalysis_optimized}")

    bcanalyzer_moptimized="llvm-bcanalyzer ${source_program}.multiispre.bc"
    bcanalysis_moptimized="$($bcanalyzer_moptimized)"
    bytes_moptimized=$(get_bytes_from_bcanalysis "${bcanalysis_moptimized}")

    raw_gvn_difference=$((bytes_gvn_optimized - bytes_unoptimized))
    percent_gvn_difference=$(bc <<< "scale=3 ; $raw_gvn_difference / $bytes_unoptimized")
    raw_difference=$((bytes_optimized - bytes_unoptimized))
    percent_difference=$(bc <<< "scale=3 ; $raw_difference / $bytes_unoptimized")
    raw_mdifference=$((bytes_moptimized - bytes_unoptimized))
    percent_mdifference=$(bc <<< "scale=3 ; $raw_mdifference / $bytes_unoptimized")

    # Measure performance and output size stats
    echo -e "=== Performance Check ==="
    echo -e "1. "
    echo -e "   a. Runtime performance of unoptimized code"
    time ./${source_program}_no_ispre > /dev/null
    echo -e ""
    echo -e "   b. Code size (IR) of unoptimized code\n"
    echo -e "      ${bytes_unoptimized} bytes"
    echo -e "2. "
    echo -e "   a. Runtime performance of GVN code"
    time ./${source_program}_gvn > /dev/null
    echo -e ""
    echo -e "   b. Code size (IR) of optimized code\n"
    echo -e "      ${bytes_gvn_optimized} bytes, ${percent_gvn_difference}% change\n"
    echo -e "3. "
    echo -e "   a. Runtime performance of ISPRE code"
    time ./${source_program}_ispre > /dev/null
    echo -e ""
    echo -e "   b. Code size (IR) of optimized code\n"
    echo -e "      ${bytes_optimized} bytes, ${percent_difference}% change\n"
    echo -e "4. "
    echo -e "   a. Runtime performance of Multipass ISPRE code"
    time ./${source_program}_multiispre > /dev/null
    echo -e ""
    echo -e "   b. Code size (IR) of optimized code\n"
    echo -e "      ${bytes_moptimized} bytes, ${percent_mdifference}% change\n"
fi

# Cleanup
if [ "$delete_intermediate" -eq 1 ] || [ "$delete_all" -eq 1 ]; then
    rm -f default.profraw ${source_program}_prof *.bc ${source_program}.profdata *_output *.ll
fi

if [ "$delete_all" -eq 1 ] ; then
    rm -f ${source_program}_ispre ${source_program}_multiispre ${source_program}_no_ispre ${source_program}_gvn
fi
