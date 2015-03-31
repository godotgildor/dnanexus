#!/bin/bash
# call_hc 0.0.1
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

set -x

# install GNU parallel!
sudo sed -i 's/^# *\(deb .*backports.*\)$/\1/' /etc/apt/sources.list
sudo apt-get update
sudo apt-get install --yes parallel

function call_hc(){

	set -x

	bam_in=$1
	WKDIR=$2
	OUTDIR=$3
	TARGET_FN=$6
	TARGET_CMD=""
	if test "$TARGET_FN"; then
		TARGET_CMD="-L $TARGET_FN"
	fi

	TOT_MEM=$(free -m | grep "Mem" | awk '{print $2}')
	N_PROC=$(nproc --all)
	
	cd $WKDIR
	
	fn_base="$(echo $bam_in | sed -e 's/\.bam$//' -e 's|.*/||')"

	# If I don't have the bam_in, it must be on DNANexus...
	if test -z "$(ls $bam_in)"; then
		# get the bam
		fn_base=$(dx describe --name "$bam_in" | sed 's/\.bam$//')
		dx download "$bam_in" -o $fn_base.bam
	fi

	# if the index doesn't exist, create it
	if test -z "$(ls $fn_base.bai)"; then
		samtools index $fn_base.bam $fn_base.bai
	fi

	BQSR_CMD=""
	if test "$(ls $fn_base.table)"; then
		BQSR_CMD="-BQSR $fn_base.table"
	fi
	
	
	# run HC to get a gVCF
	java -d64 -Xms512m -Xmx$((TOT_MEM * 19 / (N_PROC * 20) ))m -jar  /usr/share/GATK/GenomeAnalysisTK-3.3-0.jar \
	-T HaplotypeCaller \
	-R /usr/share/GATK/resources/human_g1k_v37_decoy.fasta \
	--dbsnp /usr/share/GATK/resources/dbsnp_137.b37.vcf.gz $TARGET_CMD $BQSR_CMD \
	-A AlleleBalanceBySample \
	-I $fn_base.bam \
	-o "${OUTDIR}/${fn_base}.vcf.gz" \
	-ERC GVCF \
	-pairHMM VECTOR_LOGLESS_CACHING \
	-variant_index_type LINEAR \
	-variant_index_parameter 128000
	
	# upload the results and put the resultant dx IDs into a file
	VCF_DXFN=$(dx upload "${OUTDIR}/${fn_base}.vcf.gz" --brief)
	echo "$VCF_DXFN" >> $4
	VCFIDX_DXFN=$(dx upload "${OUTDIR}/${fn_base}.vcf.gz.tbi" --brief)
	echo "$VCFIDX_DXFN" >> $5
	
	cd -

}

export -f call_hc

function call_bqsr(){

	set -x

	bam_in=$1
	WKDIR=$2
	TARGET_FN=$4
	TARGET_CMD=""
	if test "$TARGET_FN"; then
		TARGET_CMD="-L $TARGET_FN -ip 100"
	fi
	cd $WKDIR
	
	fn_base="$(echo $bam_in | sed -e 's/\.bam$//' -e 's|.*/||' )"

	# If I don't have the bam_in, it must be on DNANexus...
	if test -z "$(ls $bam_in)"; then
		# get the bam
		fn_base=$(dx describe --name "$bam_in" | sed 's/\.bam$//')
		dx download "$bam_in" -o $fn_base.bam
	fi

	# if the index doesn't exist, create it
	if test -z "$(ls $fn_base.bai)"; then
		samtools index $fn_base.bam $fn_base.bai
	fi
	
	TOT_MEM=$(free -m | grep "Mem" | awk '{print $2}')
	N_PROC=$(nproc --all)
	
	java -d64 -Xms512m -Xmx$((TOT_MEM * 19 / (N_PROC * 20) ))m -jar  /usr/share/GATK/GenomeAnalysisTK-3.3-0.jar \
	-T BaseRecalibrator \
	-R /usr/share/GATK/resources/human_g1k_v37_decoy.fasta \
	-I $fn_base.bam $TARGET_CMD \
	-knownSites /usr/share/GATK/resources/dbsnp_137.b37.vcf.gz \
	-knownSites /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.b37.vcf.gz \
	-o $WKDIR/$fn_base.table

	echo "$WKDIR/$fn_base.bam" >> $3

}
export -f call_bqsr

main() {
	
	# set the shell to work w/ GNU parallel
	export SHELL="/bin/bash"

    echo "Value of bam: '$bam'"
    echo "Value of bam_idx: '$bam_idx'"
    echo "Value of target: '$target'"

    # The following line(s) use the dx command-line tool to download your file
    # inputs to the local file system using variable names for the filenames. To
    # recover the original filenames, you can use the output of "dx describe
    # "$variable" --name".
    
    TARGET_FN=""
    if [ -n "$target" ]; then
    	TARGET_FN="$PWD/target.bed"
        dx download "$target" -o target.bed
    fi

	WKDIR=$(mktemp -d)
	OUTDIR=$(mktemp -d)
	DXBAM_LIST=$(mktemp)
	DX_VCF_LIST=$(mktemp)
	DX_VCFIDX_LIST=$(mktemp)
	
	cd $WKDIR
	
	for i in "${!bam_idx[@]}"; do	
		fn_base=$(dx describe --name "${bam_idx[$i]}" | sed 's/\.ba\(m\.ba\)*i$/.bai/')
		dx download "${bam_idx[$i]}" -o $fn_base
	done
	
	for i in "${!bam[@]}"; do
		echo "${bam[$i]}" >> $DXBAM_LIST
	done
	
	# get the resources we need in /usr/share/GATK
	sudo mkdir -p /usr/share/GATK/resources
	sudo chmod -R a+rwX /usr/share/GATK
		
	#dx download $(dx find data --name "GenomeAnalysisTK-3.2-2.jar" --project $DX_RESOURCES_ID --brief) -o /usr/share/GATK/GenomeAnalysisTK-3.2-2.jar
	dx download $(dx find data --name "GenomeAnalysisTK-3.3-0.jar" --project $DX_RESOURCES_ID --brief) -o /usr/share/GATK/GenomeAnalysisTK-3.3-0.jar
	dx download $(dx find data --name "dbsnp_137.b37.vcf.gz" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/dbsnp_137.b37.vcf.gz
	dx download $(dx find data --name "dbsnp_137.b37.vcf.gz.tbi" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/dbsnp_137.b37.vcf.gz.tbi
	dx download $(dx find data --name "Mills_and_1000G_gold_standard.indels.b37.vcf.gz" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.b37.vcf.gz
	dx download $(dx find data --name "Mills_and_1000G_gold_standard.indels.b37.vcf.gz.tbi" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.b37.vcf.gz.tbi
	dx download $(dx find data --name "human_g1k_v37_decoy.fasta" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta
	dx download $(dx find data --name "human_g1k_v37_decoy.fasta.fai" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta.fai
	dx download $(dx find data --name "human_g1k_v37_decoy.dict" --project $DX_RESOURCES_ID --folder /resources --brief) -o /usr/share/GATK/resources/human_g1k_v37_decoy.dict

	if test "$call_bqsr" = "true"; then
		BAM_LIST=$(mktemp)
		parallel -j $(nproc --all) -u --gnu call_bqsr :::: $DXBAM_LIST ::: $WKDIR ::: $BAM_LIST ::: $TARGET_FN
		DXBAM_LIST=$BAM_LIST
	fi


	parallel -j $(nproc --all) -u --gnu call_hc :::: $DXBAM_LIST ::: $WKDIR ::: $OUTDIR ::: $DX_VCF_LIST ::: $DX_VCFIDX_LIST ::: $TARGET_FN
	
	while read vcf_fn; do
		dx-jobutil-add-output vcf_fn "$vcf_fn" --class=array:file
	done < $DX_VCF_LIST

	while read vcfidx_fn; do
	    dx-jobutil-add-output vcfidx_fn "$vcfidx_fn" --class=array:file
	done <$DX_VCFIDX_LIST
}
