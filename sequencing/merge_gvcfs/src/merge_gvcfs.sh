#!/bin/bash
# call_genotypes 0.0.1
# Generated by dx-app-wizard.
#
# Basic execution pattern: Your app will run on a single machine from
# beginning to end.
#
# Your job's input variables (if any) will be loaded as environment
# variables before this script runs.  Any array inputs will be loaded
# as bash arrays.
#
# Any code outside of main() (or any entry point you may add) is
# ALWAYS executed, followed by running the entry point itself.
#
# See https://wiki.dnanexus.com/Developer-Portal for tutorials on how
# to modify this file.


# install GNU parallel!
sudo sed -i 's/^# *\(deb .*backports.*\)$/\1/' /etc/apt/sources.list
sudo apt-get update
sudo apt-get install --yes parallel

set -x

RERUN=1

while test $RERUN -ne 0; do
	sudo pip install pytabix
	RERUN="$?"
done


#mkfifo /LOG_SPLITTER
#stdbuf -oL tee /LOGS < /LOG_SPLITTER &

#splitter_pid=$!
#exec > /LOG_SPLITTER 2>&1

#save_logs() {
#	if test -f "$HOME/job_error.json" -a "$(cat $HOME/job_error.json | jq .error.type | sed 's/\"//g')" = "AppInternalError"; then
#	    dx upload --brief /LOGS --destination "${DX_PROJECT_CONTEXT_ID}:/${DX_JOB_ID}.log" >/dev/null
#   	echo "Full logs saved in ${DX_PROJECT_CONTEXT_ID}:/${DX_JOB_ID}.log"
#    fi
#}

#trap save_logs EXIT

function download_resources() {

	# get the resources we need in /usr/share/GATK
	sudo mkdir -p /usr/share/GATK/resources
	sudo chmod -R a+rwX /usr/share/GATK

	dx download $(dx find data --name "GenomeAnalysisTK-3.3-0.jar" --project $DX_RESOURCES_ID --brief) -o /usr/share/GATK/GenomeAnalysisTK-3.3-0.jar
	dx download $(dx find data --name "GenomeAnalysisTK-3.3-0-custom.jar" --project $DX_RESOURCES_ID --brief) -o /usr/share/GATK/GenomeAnalysisTK-3.3-0-custom.jar
	dx download $(dx find data --name "dbsnp_137.b37.vcf.gz" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/dbsnp_137.b37.vcf.gz
	dx download $(dx find data --name "dbsnp_137.b37.vcf.gz.tbi" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/dbsnp_137.b37.vcf.gz.tbi
	dx download $(dx find data --name "human_g1k_v37_decoy.fasta" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta
	dx download $(dx find data --name "human_g1k_v37_decoy.fasta.fai" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta.fai
	dx download $(dx find data --name "human_g1k_v37_decoy.dict" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/human_g1k_v37_decoy.dict
	
}

function get_dxids() {
	dx describe "$1" --json | jq .id | sed 's/\"//g' >> $2
}
export -f get_dxids

function parallel_download() {
	#set -x
	cd $2
	dx download "$1"
	cd - >/dev/null
}
export -f parallel_download

function merge_gvcf() {
	#set -x
	f=$1

	WKDIR=$3
	CPWD="$PWD"
	cd $WKDIR

	GVCF_LIST=$(mktemp)
		
	TOT_MEM=$(free -m | grep "Mem" | awk '{print $2}')
	N_PROC=$4
	ADDED_TBI=0
	
	while read dx_gvcf; do
		gvcf_fn=$(dx describe --name "$dx_gvcf")
		dx download "$dx_gvcf"
		
		if test "$(echo $gvcf_fn | grep '\.gz$')" -a -z "$(ls $gvcf_fn.tbi 2>/dev/null)"; then
			tabix -p vcf $gvcf_fn
			ADDED_TBI=1
		fi
		
		echo $PWD/$gvcf_fn >> $GVCF_LIST
	done < $f
	
	GATK_LOG=$(mktemp)
	java -d64 -Xms512m -Xmx$((TOT_MEM * 19 / (N_PROC * 20) ))m -XX:+UseSerialGC -jar /usr/share/GATK/GenomeAnalysisTK-3.3-0-custom.jar \
	-T CombineGVCFs \
	-R /usr/share/GATK/resources/human_g1k_v37_decoy.fasta \
	$(cat $GVCF_LIST | sed "s|^|-V |" | tr '\n' ' ') \
	-o "$f.vcf.gz" 2>$GATK_LOG
	
	if test "$?" -ne 0; then
		# Please add this to the list to be re-run
		echo $f >> $5
		echo "Error running GATK, log below:"
		cat $GATK_LOG
		rm $GATK_LOG
		sleep 5
		rm "$f.vcf.gz" || true
		rm "$f.vcf.gz.tbi" || true
	else
		echo "$f.vcf.gz" >> $2
	fi
	
	# clean up the working directory
	for tmpfn in $(cat $GVCF_LIST); do
		rm $tmpfn
		if test "$ADDED_TBI" -ne 0; then 
			rm $tmpfn.tbi || true
		fi
	done
	
	rm $GVCF_LIST
	cd "$CPWD"
}
export -f merge_gvcf

function dl_index() {
	#set -x
	cd "$2"
	fn=$(dx describe --name "$1")
	dx download "$1" -o "$fn"
	if test -z "$(ls $fn.tbi)"; then
		tabix -p vcf $fn
	fi
	echo "$2/$fn" >> $3
}
export -f dl_index

function upload_files() {
	#set -x
	fn_list=$1
	
	VCF_TMPF=$(mktemp)
	VCFIDX_TMPF=$(mktemp)
	for f in $(cat $fn_list); do
		vcf_fn=$(dx upload --brief $f)
		echo $vcf_fn >> $VCF_TMPF
		vcfidx_fn=$(dx upload --brief $f.tbi)
		echo $vcfidx_fn >> $VCFIDX_TMPF
	done
	
	echo $VCF_TMPF >> $2
	echo $VCFIDX_TMPF >> $3
}

export -f upload_files

function dl_merge_interval() {
	#set -x
	INTERVAL_FILE=$1
	
	# If we have no intervals, just exit
	if test "$(cat $INTERVAL_FILE | wc -l)" -eq 0; then
		exit 0
	fi
	
	#echo "Interval File Contents:"
	#cat $INTERVAL_FILE
	
	# $INTERVAL holds the overall interval from 1st to last
	INTERVAL="$(head -1 $INTERVAL_FILE | cut -f1-2 | tr '\t' '.')_$(tail -1 $INTERVAL_FILE | cut -f3)"
	if test "$(echo $INTERVAL | grep -v '\.')"; then
		#If we're here, we're parallelizing by chromosome, not by regions
		INTERVAL=$(head -1 $INTERVAL_FILE | cut -f1)
	fi
	echo "Interval: $INTERVAL"
	INTERVAL_STR="$(echo $INTERVAL | tr '.' ':' | tr '_' '-' | sed 's/[:-]*$//')"
	CHR="$(echo $INTERVAL | sed 's/\..*//')"
	DX_GVCF_FILES=$2
	INDEX_DIR=$3
	PREFIX=$4
	N_PROC=$5
	RERUN_FILE=$6
	
	IDX_NAMES=$(mktemp)
	ls $INDEX_DIR/*.tbi | sed -e 's|.*/\(.*\)\.tbi$|\1\t&|' | sort -k1,1 > $IDX_NAMES
	
	WKDIR=$(mktemp -d)
	cd $WKDIR
	
	set -o 'pipefail'
	
	GVCF_IDX_MAPPING=$(mktemp)
	# First, match up the GVCF to its index
	while read dxfn; do
		GVCF_NAME=$(dx describe --name "$dxfn")
		GVCF_DXID=$(dx describe --json "$dxfn" | jq .id | sed 's/\"//g')
		GVCF_BASE=$(echo "$GVCF_NAME" | sed 's/.vcf\.gz$//')
		GVCF_IDX=$(join -o '2.2' -j1 <(echo "$GVCF_NAME") $IDX_NAMES)
		
		
		#GVCF_URL=$(dx make_download_url "$dxfn")
		
		#GVCF_URL=$(dx describe --json "$dxfn" | jq .id | sed 's/"//g')
		# I had some issues w/ unsorted VCFs, so take a shortcus and sort by the
		# 2nd column - no need to sort on 1st, as these MUST all be on the
		# same chromosome
		RERUN=1
		MAX_RETRY=5
		while test $RERUN -ne 0 -a $MAX_RETRY -gt 0; do
			download_part.py -f "$GVCF_DXID" -i "$GVCF_IDX" -L "$INTERVAL_STR" -o $GVCF_BASE.$INTERVAL.vcf.gz -H
			RERUN="$?"
			MAX_RETRY=$((MAX_RETRY - 1))
		done
		
		# only do the tabix indexing if we succeeded.  This should cause a 
		# failure downstream if an issue occurs
		if test $RERUN -eq 0; then
			tabix -p vcf $WKDIR/$GVCF_BASE.$INTERVAL.vcf.gz
		fi
	done < $DX_GVCF_FILES
	
	TOT_MEM=$(free -m | grep "Mem" | awk '{print $2}')
	#N_PROC=$(nproc --all)

	GATK_LOG=$(mktemp)

	# Ask for 95% of total per-core memory
	java -d64 -Xms512m -Xmx$((TOT_MEM * 19 / (N_PROC * 20) ))m -XX:+UseSerialGC -jar /usr/share/GATK/GenomeAnalysisTK-3.3-0-custom.jar \
	-T CombineGVCFs \
	-R /usr/share/GATK/resources/human_g1k_v37_decoy.fasta -L $CHR\
	$(ls *.vcf.gz | sed "s|^|-V |" | tr '\n' ' ') \
	-o "$PREFIX.$INTERVAL.vcf.gz" 2>$GATK_LOG
	
	# If GATK failed for any reason, add this interval file to the re-run list
	if test "$?" -ne 0; then
		echo "GATK Failed: Log below"
		cat $GATK_LOG
		echo "$1" >> $RERUN_FILE
	fi
}
export -f dl_merge_interval

function merge_intervals(){

	echo "Resources: $DX_RESOURCES_ID"

	# set the shell to work w/ GNU parallel
	export SHELL="/bin/bash"

	# arguments:
	# gvcfidxs - single file containing all gvcf indexes we MIGHT need, one per line
	# gvcfs - single file, containing all gvcfs
	# PREFIX - the prefix of the gvcf to use (final name will be $PREFIX.$CHR.vcf.gz)

	# I will have an array of files, each containing all of the gvcfs to merge
	# for a single chromosome
	
	# Also, I'll have a single file with all of the gvcfidxs created - just 
	# download ALL of them, even if they don't apply!
	
	download_resources
	
	INDEX_DIR=$(mktemp -d)
	
	# download ALL of the indexes (in parallel!)
	GVCFIDX_FN=$(mktemp)
	dx download "$gvcfidxs" -f -o $GVCFIDX_FN
	parallel --gnu -j $(nproc --all) parallel_download :::: $GVCFIDX_FN ::: $INDEX_DIR
	
	# download the target file and the list of GVCFs
	TARGET_FILE=$(mktemp)
	dx download "$target" -f -o $TARGET_FILE
	
	GVCF_FN=$(mktemp)
	dx download "$gvcfs" -f -o $GVCF_FN
	
	# To reduce startup overhead of GATK, let's do multiple intervals at a time
	# This variable tells us to use $OVERSUB * $(nproc) different GATK runs
	OVERSUB=1
	SPLIT_DIR=$(mktemp -d)
	cd $SPLIT_DIR
	NPROC=$(nproc --all)
	
	# if we are given a list of intervals, "targeted" will be defined, o/w, we assume the target list will be by chromosome
	# and in that case, we only want one line per file
	if test "$targeted"; then
		N_BATCHES=$((OVERSUB * NPROC))
		split -a $(echo "scale=0; 1+l($N_BATCHES)/l(10)" | bc -l) -d -n l/$N_BATCHES $TARGET_FILE "interval_split."
	else
		N_BATCHES=$(cat $TARGET_FILE | wc -l)	
		split -a $(echo "scale=0; 1+l($N_BATCHES)/l(10)" | bc -l) -d -l 1 $TARGET_FILE "interval_split."
	fi
	
	cd - >/dev/null
	MASTER_TARGET_LIST=$(mktemp)
	ls -1 $SPLIT_DIR/interval_split.* > $MASTER_TARGET_LIST	
	
	# iterate over the intervals in TARGET_FILE, downloading only what is needed
	OUTDIR=$(mktemp -d)
	OUTDIR_PREF="$OUTDIR/combined"

	N_CHUNKS=$(cat $MASTER_TARGET_LIST | wc -l)	
	RERUN_FILE=$(mktemp)
	N_RUNS=1
	N_CORES=$(nproc)
	N_JOBS=1
	
	# each run, we will decrease the number of cores available until we're at a single core at a time (using ALL the memory)
	while test $N_CHUNKS -gt 0 -a $N_JOBS -gt 0; do	
	
		N_JOBS=$(echo "$N_CORES/2^($N_RUNS - 1)" | bc)
		# make sure we have a minimum of 1 job, please!
		N_JOBS=$((N_JOBS > 0 ? N_JOBS : 1))
	
		parallel --gnu -j $N_JOBS dl_merge_interval :::: $MASTER_TARGET_LIST ::: $GVCF_FN ::: $INDEX_DIR ::: $OUTDIR_PREF ::: $N_JOBS ::: $RERUN_FILE
		
		PREV_CHUNKS=$N_CHUNKS
		N_CHUNKS=$(cat $RERUN_FILE | wc -l)
		mv $RERUN_FILE $MASTER_TARGET_LIST
		RERUN_FILE=$(mktemp)
		N_RUNS=$((N_RUNS + 1))
		# just to make N_JOBS 0 at the conditional when we ran only a single job!
		N_JOBS=$((N_JOBS - 1))
	done
	
	# We need to be certain that nothing remains to be merged!
	if test "$N_CHUNKS" -ne 0; then
		dx-jobutil-report-error "ERROR: Could not merge one or more interval chunks; try an instance with more memory!"
	fi

	
	# OK, at this point everything should be merged, so we'll go ahead and concatenate everything in $OUTDIR
	FINAL_DIR=$(mktemp -d)
	TOT_MEM=$(free -m | grep "Mem" | awk '{print $2}')
	java -d64 -Xms512m -Xmx$((TOT_MEM * 9 / 10))m -XX:+UseSerialGC -jar /usr/share/GATK/GenomeAnalysisTK-3.3-0-custom.jar \
	-T CombineVariants -nt $(nproc --all) --assumeIdenticalSamples \
	$(ls $OUTDIR/*.vcf.gz | sed 's/^/-V /' | tr '\n' ' ') \
	-R /usr/share/GATK/resources/human_g1k_v37_decoy.fasta \
	-genotypeMergeOptions UNSORTED \
	-o $FINAL_DIR/$PREFIX.vcf.gz
	
	VCF_OUT=$(dx upload $FINAL_DIR/$PREFIX.vcf.gz --brief)
	VCFIDX_OUT=$(dx upload $FINAL_DIR/$PREFIX.vcf.gz.tbi --brief)
	
	dx-jobutil-add-output vcf "$VCF_OUT"
	dx-jobutil-add-output vcfidx "$VCFIDX_OUT"

}	

function concatenate_gvcfs(){

	echo "Resources: $DX_RESOURCES_ID"
	# set the shell to work w/ GNU parallel
	export SHELL="/bin/bash"

	# Arguments:
	# gvcfidxs (optional)
	# array of files, each containing a "dx download"-able file, one per line
	# and the files are tbi indexes of the gvcf.gz files
	# gvcfs (mandatory)
	# array of files, as above, where each line is a single gvcf file
	# PREFIX (mandatory)
	# the prefix to use for the single resultant gvcf

	download_resources
	
	# download my gvcfidx_list
	DX_GVCFIDX_LIST=$(mktemp)
	WKDIR=$(mktemp -d)

	for i in "${!gvcfidxs[@]}"; do	
		dx cat "${gvcfidxs[$i]}" >> $DX_GVCFIDX_LIST
	done
	
	cd $WKDIR
	
	parallel -u --gnu -j $(nproc --all) parallel_download :::: $DX_GVCFIDX_LIST ::: $WKDIR
	
	# OK, now all of the gvcf indexes are in $WKDIR, time to download
	# all of the GVCFs in parallel
	DX_GVCF_LIST=$(mktemp)
	for i in "${!gvcfs[@]}"; do	
		dx cat "${gvcfs[$i]}" >> $DX_GVCF_LIST
	done
	
	# download (and index if necessary) all of the gVCFs
	GVCF_LIST=$(mktemp)	
	parallel -u --gnu -j $(nproc --all) dl_index :::: $DX_GVCF_LIST ::: $WKDIR ::: $GVCF_LIST
	
	# Now, merge the gVCFs into a single gVCF
	FINAL_DIR=$(mktemp -d)
	TOT_MEM=$(free -m | grep "Mem" | awk '{print $2}')
	java -d64 -Xms512m -Xmx$((TOT_MEM * 9 / 10))m -jar /usr/share/GATK/GenomeAnalysisTK-3.3-0-custom.jar \
	-T CombineVariants -nt $(nproc --all) --assumeIdenticalSamples \
	$(cat $GVCF_LIST | sed 's/^/-V /' | tr '\n' ' ') \
	-R /usr/share/GATK/resources/human_g1k_v37_decoy.fasta \
	-genotypeMergeOptions UNSORTED \
	-o $FINAL_DIR/$PREFIX.vcf.gz
	
	# and upload it and we're done!
	DX_GVCF_UPLOAD=$(dx upload "$FINAL_DIR/$PREFIX.vcf.gz" --brief)
	DX_GVCFIDX_UPLOAD=$(dx upload "$FINAL_DIR/$PREFIX.vcf.gz.tbi" --brief)
	
	dx-jobutil-add-output gvcf $DX_GVCF_UPLOAD --class=file
	dx-jobutil-add-output gvcfidx $DX_GVCFIDX_UPLOAD --class=file
	
}


# entry point for merging into a single gVCF
function single_merge_subjob() {

	echo "Resources: $DX_RESOURCES_ID"

	# set the shell to work w/ GNU parallel
	export SHELL="/bin/bash"
	
	# If we are working with both GVCFs and their index files, let's break it up by interval
	# If no interval given, just break up by chromosome

	gvcfidxfn=$(dx describe "$gvcfidxs" --json | jq .id | sed 's/"//g')
	gvcffn=$(dx describe "$gvcflist" --json | jq .id | sed 's/"//g')

	OVER_SUB=1
	INTERVAL_LIST=$(mktemp)
	ORIG_INTERVALS=$(mktemp)
	SPLIT_DIR=$(mktemp -d)
	MERGE_ARGS=""

	if test "$target"; then
		OVER_SUB=512
		MERGE_ARGS="$MERGE_ARGS -itargeted:int=1"
		
		TARGET_FILE=$(mktemp)
		dx download "$target" -f -o $TARGET_FILE
		CHROM_LIST=$(mktemp)
		cut -f1 $TARGET_FILE  | sort -u > $CHROM_LIST
		# first, do the numeric chromosomes, in order
		for chr in $(grep '^[0-9]' $CHROM_LIST | sort -n); do
			grep "^$chr\W" $TARGET_FILE | interval_pad.py $padding | tr ' ' '\t' | sort -n -k2,3 >> $INTERVAL_LIST
		done
		
		# Now do the non-numeric chromosomes in order
		for chr in $(grep '^[^0-9]' $CHROM_LIST | sort); do
			grep "^$chr\W" $TARGET_FILE | interval_pad.py $padding | tr ' ' '\t' | sort -n -k2,3 >> $INTERVAL_LIST
		done
		
		rm $CHROM_LIST
		rm $TARGET_FILE
		
		# OK, now split the interval list into files of OVER_SUB * # proc
		cd $SPLIT_DIR
		NPROC=$(nproc --all)
	
		#N_INT=$(cat $INTERVAL_LIST | wc -l)
		#N_BATCHES=$((N_INT / (OVER_SUB * NPROC) ))
	
		# BUT, let's make sure that they're not crossing chromosome boundaries (how embarrassing!)
		# also, all the chromosomes should be together, so no need to sort
		# this may allow us to use CatVariants later on...
		for CHR in $(cut -f1 $INTERVAL_LIST | uniq); do
			CHR_LIST=$(mktemp)
			cat $INTERVAL_LIST | sed -n "/^$CHR[ \t].*/p" > $CHR_LIST
			N_CHR_TARGET=$(cat $CHR_LIST | wc -l)
			N_BATCHES=$((N_CHR_TARGET / (OVER_SUB * NPROC) + 1))			
			split -a $(echo "scale=0; 1+l($N_BATCHES)/l(10)" | bc -l) -d -n l/$N_BATCHES $CHR_LIST "interval_split.$CHR."
			rm $CHR_LIST
		done
						
	else
		TMPWKDIR=$(mktemp -d)
		cd $TMPWKDIR
		idxfn=$(dx cat "$gvcfidxs" | head -1)
		vcf_name=$(dx describe --name "$idxfn" | sed 's/\.tbi$//')
		dx download "$idxfn"
		# get a list of chromosomes, but randomize
		tabix -l $vcf_name | shuf > $INTERVAL_LIST
		N_CHR=$(cat $INTERVAL_LIST | wc -l)
		cd -
		
		cd $SPLIT_DIR
		NPROC=$(nproc --all)
	
		#N_INT=$(cat $INTERVAL_LIST | wc -l)
		#N_BATCHES=$((N_INT / (OVER_SUB * NPROC) ))
		N_BATCHES=$((N_CHR / (NPROC) + 1 ))			
		
		split -a $(echo "scale=0; 1+l($N_BATCHES)/l(10)" | bc -l) -d -l $NPROC $INTERVAL_LIST "interval_split."	
		
		rm -rf $TMPWKDIR
	fi
	
	CIDX=0
	CONCAT_ARGS=""
	for f in interval_split.*; do
		echo "interval file:"
		cat $f
		int_fn=$(dx upload $f --brief)
		# run a subjob that merges the input VCFs on the given target file
		merge_job[$CIDX]=$(dx-jobutil-new-job merge_intervals $MERGE_ARGS -igvcfidxs:file="$gvcfidxfn" -igvcfs:file="$gvcffn" -itarget:file="$int_fn" -iPREFIX="$PREFIX.$CIDX")
		CONCAT_ARGS="$CONCAT_ARGS -ivcfidxs=${merge_job[$CIDX]}:vcfidx -ivcfs=${merge_job[$CIDX]}:vcf"
		CIDX=$((CIDX + 1))
	done
	# concatenate the results
	concat_job=$(dx run combine_variants -iprefix="$PREFIX" $CONCAT_ARGS --brief)

	dx-jobutil-add-output gvcf "$concat_job:vcf_out" --class=jobref
	dx-jobutil-add-output gvcfidx "$concat_job:vcfidx_out" --class=jobref	
}

# entry point for merging VCFs
function merge_subjob() {

	echo "Resources: $DX_RESOURCES_ID"
	
	# set the shell to work w/ GNU parallel
	export SHELL="/bin/bash"
	
	# Get the prefix from the project, subbing _ for spaces
	if test -z "$PREFIX"; then
		PREFIX="$(dx describe --name $project | sed 's/  */_/g')"
	fi

	LIST_DIR=$(mktemp -d)
	dx download "$gvcflist" -o $LIST_DIR/GVCF_LIST
		
	N_BATCHES=$nbatch
	N_CORES=$(nproc --all)
	
	PREFIX="$PREFIX.$jobidx"
	
	download_resources

	GVCF_TMP=$(mktemp)
	GVCF_TMPDIR=$(mktemp -d)
		
	sudo chmod a+rw $GVCF_TMP
	
	cd  $GVCF_TMPDIR
		
	if test "$gvcfidxs"; then
		DX_GVCFIDX_LIST=$(mktemp)
		dx download "$gvcfidxs" -f -o $DX_GVCFIDX_LIST
	
		parallel --gnu -j $(nproc --all) parallel_download :::: $DX_GVCFIDX_LIST ::: $GVCF_TMPDIR
	fi
		
	GVCF_LIST_SHUF=$(mktemp)
	cat $LIST_DIR/GVCF_LIST | shuf  > $GVCF_LIST_SHUF
	split -a $(echo "scale=0; 1+l($N_BATCHES)/l(10)" | bc -l) -n l/$N_BATCHES -d $GVCF_LIST_SHUF "gvcflist."
	cd -
	sudo chmod -R a+rwX $GVCF_TMPDIR

	TMP_GVCF_LIST=$(mktemp)
	ls -1 ${GVCF_TMPDIR}/gvcflist.* > $TMP_GVCF_LIST


	N_CHUNKS=$(cat $TMP_GVCF_LIST | wc -l)	
	RERUN_FILE=$(mktemp)
	N_RUNS=1
	N_CORES=$(nproc)
	N_JOBS=1
	
	# each run, we will decrease the number of cores available until we're at a single core at a time (using ALL the memory)
	while test $N_CHUNKS -gt 0 -a $N_JOBS -gt 0; do	
	
		N_JOBS=$(echo "$N_CORES/2^($N_RUNS - 1)" | bc)
		# make sure we have a minimum of 1 job, please!
		N_JOBS=$((N_JOBS > 0 ? N_JOBS : 1))
	
		parallel -u -j $N_JOBS --gnu merge_gvcf :::: $TMP_GVCF_LIST ::: $GVCF_TMP ::: $GVCF_TMPDIR ::: $N_JOBS ::: $RERUN_FILE
		
		PREV_CHUNKS=$N_CHUNKS
		N_CHUNKS=$(cat $RERUN_FILE | wc -l)
		mv $RERUN_FILE $TMP_GVCF_LIST
		RERUN_FILE=$(mktemp)
		N_RUNS=$((N_RUNS + 1))
		# just to make N_JOBS 0 at the conditional when we ran only a single job!
		N_JOBS=$((N_JOBS - 1))
	done
	
	# We need to be certain that nothing remains to be merged!
	if test "$N_CHUNKS" -ne 0; then
		dx-jobutil-report-error "ERROR: Could not merge one or more interval chunks; try an instance with more memory!"
	fi	
	
	CIDX=1
	
	FINAL_DIR=$(mktemp -d)
	
	GVCF_SORTED=$(mktemp)
	sed -i 's|^.*/gvcflist\.\([^.]*\)\.vcf\.gz$|\1\t&|' $GVCF_TMP 
	sort -k1,1 -n $GVCF_TMP | cut -f2 > $GVCF_SORTED
	
	for l in $(cat $GVCF_SORTED); do
		mv $l ${FINAL_DIR}/$PREFIX.$CIDX.vcf.gz
		mv $l.tbi ${FINAL_DIR}/$PREFIX.$CIDX.vcf.gz.tbi
			
		VCF_DXFN=$(dx upload ${FINAL_DIR}/$PREFIX.$CIDX.vcf.gz --brief)
		VCFIDX_DXFN=$(dx upload ${FINAL_DIR}/$PREFIX.$CIDX.vcf.gz.tbi --brief)
	
		dx-jobutil-add-output gvcf$CIDX "$VCF_DXFN" --class=file
		dx-jobutil-add-output gvcfidx$CIDX "$VCFIDX_DXFN" --class=file
		
		CIDX=$((CIDX + 1))
	done

}


main() {

	if test -z "$project"; then
		project=$DX_PROJECT_CONTEXT_ID
	fi
	
	echo "Resources: $DX_RESOURCES_ID"
	
	export SHELL="/bin/bash"

    echo "Value of project: '$project'"  
    echo "Value of folder: '$folder'"
	echo "Value of N_BATCHES: '$N_BATCHES'"
	
	N_GVCF="${#gvcfs[@]}"
    GVCF_LIST=$(mktemp)
    SUBJOB_ARGS=""
	if test "$N_GVCF" -gt 0 ; then
	
		# use the gvcf list provided
		for i in "${!gvcfs[@]}"; do
			echo "${gvcfs[$i]}" >> $GVCF_LIST
		done

		# also, pass the gvcf index list as well!
		if test "${#gvcfidxs[@]}" -gt 0; then
		    GVCFIDX_LIST=$(mktemp)

			for i in "${!gvcfidxs[@]}"; do
				echo "${gvcfidxs[$i]}" >> $GVCFIDX_LIST
			done
			
			dx_gidxlist=$(dx upload $GVCFIDX_LIST --brief)
			SUBJOB_ARGS="$SUBJOB_ARGS -igvcfidxs:file=$dx_gidxlist"
			
			rm $GVCFIDX_LIST
		fi
		
	elif test "$folder"; then
		parallel -u --gnu -j $(nproc --all) get_dxids :::: <(dx ls "$project:$folder" | grep '\.gz$' | sed "s|^|$project:$folder/|") ::: $GVCF_LIST
	else
		dx-jobutil-report-error "ERROR: you must provide either a list of gvcfs OR a directory containing gvcfs"
	fi
    
    if test "$target"; then
    	SUBJOB_ARGS="$SUBJOB_ARGS -itarget:file=$(echo $target | sed 's/.*\(file-[^"]*\)".*/\1/')"
    	if test "$padding"; then
    		SUBJOB_ARGS="$SUBJOB_ARGS -ipadding:int=$padding"
    	fi
    fi
    
    N_GVCF=$(cat $GVCF_LIST | wc -l)
    echo "# GVCF: $N_GVCF"
    
    if test $N_GVCF -le $N_BATCHES; then
    	dx-jobutil-report-error "ERROR: The number of input gVCFs is <= the number of requested output gVCFs, nothing to do!"
    fi	

	# assume that the master instance will filter down to the children    
   	N_CORE_SUBJOB=$(nproc --all)
    N_SUBJOB=$((N_BATCHES / N_CORE_SUBJOB))
    if test $N_SUBJOB -eq 0; then
    	# minimum of 1 subjob, please!
        N_SUBJOB=1
        N_CORE_SUBJOB=$N_BATCHES
    fi
    
    # move the special logic testing N_BATCHES==1 here
    if test $N_BATCHES -eq 1; then
    		
		dx_gvcflist=$(dx upload $GVCF_LIST --brief)
	
		single_job=$(dx-jobutil-new-job single_merge_subjob -iPREFIX="$PREFIX" -igvcflist="$dx_gvcflist" $SUBJOB_ARGS)
		
		# and upload it and we're done!
		dx-jobutil-add-output vcf_fn --array "$single_job:gvcf" --class=jobref
		dx-jobutil-add-output vcf_idx_fn --array "$single_job:gvcfidx" --class=jobref
    
    else
   
		GVCF_TMPDIR=$(mktemp -d)
		cd  $GVCF_TMPDIR
		GVCF_LIST_SHUF=$(mktemp)
		cat $GVCF_LIST | shuf > $GVCF_LIST_SHUF
		split -a $(echo "scale=0; 1+l($N_SUBJOB)/l(10)" | bc -l) -n l/$N_SUBJOB -d $GVCF_LIST_SHUF "gvcflist."
		cd -
	
	
	
		CIDX=1
		# Now, kick off the subjobs for every file!
		for f in $(ls -1 $GVCF_TMPDIR | sed 's|^.*/||'); do
			# upload the gvcflist
			GVCF_DXFN=$(dx upload $GVCF_TMPDIR/$f --brief)
			# start the sub-job with the project, folder and gvcf list
			subjob=$(dx-jobutil-new-job merge_subjob -iproject="$project" -ifolder="$folder" -igvcflist:file="$GVCF_DXFN" -iPREFIX="$PREFIX" -ijobidx=$CIDX -inbatch=$N_CORE_SUBJOB $SUBJOB_ARGS)
		
			# the output of the subjob will be gvcfN and gvcfidxN, for N=1:#cores
			for c in $(seq 1 $N_CORE_SUBJOB); do
				dx-jobutil-add-output vcf_fn --array "${subjob}:gvcf$c" --class=jobref
				dx-jobutil-add-output vcf_idx_fn --array "${subjob}:gvcfidx$c" --class=jobref
			done		
		
			CIDX=$((CIDX + 1))
		
			# reap the array of gvcf/gvcf_index and add it to the output of this job
		done
	
	fi
}
