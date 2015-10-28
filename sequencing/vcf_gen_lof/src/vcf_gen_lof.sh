#!/bin/bash
# vcf_annotate 0.0.1
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
set -o pipefail

main() {

    echo "Value of vcf_fn: '$vcf_fn'"
    echo "Value of prefix: '$prefix'"
    
    FN=$(dx describe --name "$vcf_fn")
    if test -z "$prefix"; then
    	prefix="$(echo "$FN" | sed 's/\.vcf\(\.gz\)*$//').LOF"
    fi

    # The following line(s) use the dx command-line tool to download your file
    # inputs to the local file system using variable names for the filenames. To
    # recover the original filenames, you can use the output of "dx describe
    # "$variable" --name".

	WKDIR=$(mktemp -d)
	OUTDIR=$(mktemp -d)
	cd $WKDIR
	
	LOCALFN="vcf_input.vcf"
    dx download "$vcf_fn" -o $LOCALFN
	if test "$(echo "$FN" | grep '\.gz$')"; then
		mv $LOCALFN $LOCALFN.gz
	else
		bgzip $LOCALFN
	fi

	LOCALFN="$LOCALFN.gz"
	tabix -p vcf $LOCALFN
	
	TOT_MEM=$(free -m | grep "Mem" | awk '{print $2}')
    # only ask for 90% of total system memory
    TOT_MEM=$((TOT_MEM * 9 / 10)) 
	
	if test "$snps_only" = "true"; then
		# Download the necessary files for GATK SelectVariants
		sudo mkdir -p /usr/share/GATK/resources
		sudo chmod -R a+rwX /usr/share/GATK
			
		dx download "$DX_RESOURCES_ID:/GATK/jar/GenomeAnalysisTK-3.4-46.jar" -o /usr/share/GATK/GenomeAnalysisTK-3.4-46.jar
		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta" -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta
		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta.fai" -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta.fai
		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.dict" -o /usr/share/GATK/resources/human_g1k_v37_decoy.dict
	
		java -d64 -Xms512m -Xmx${TOT_MEM}m -jar /usr/share/GATK/GenomeAnalysisTK-3.4-46.jar \
			-T SelectVariants \
			-nt $(nproc --all) \
			-R /usr/share/GATK/resources/human_g1k_v37_decoy.fasta \
			-V $LOCALFN -selectType SNP -o input.snp.vcf.gz
		
		LOCALFN="input.snp.vcf.gz"
	fi


    # generate AF annotation, 1 per variant
    # only needed if min_maf > 0 OR max_maf < 1
    if (( $(bc <<< "$min_maf > 0 || $max_maf < 1") )); then
    
    	# If no "AF" exists, throw an error!
    	
    	vcf-query $LOCALFN -f "%CHROM\t%POS\t%INFO/AF\n" | awk -F '\t|,' '{s = 0; m=0; for(i=3;i<=NF;i++){s+=$i; if($i>m){m=$i}} print $1 "\t" $2 "\t"  (1-s < m ? 1-s : m) }' > maf_anno
        awk "{if(\$3 >= $min_maf && \$3 <= $max_maf){print \$1 \"\\t\" \$2}}" maf_anno | tee maf_pass | wc -l
        
    fi
	
	# generate SNPEff annotation, 1 per variant, per line
	if test "${#snpEff_mod[@]}" -gt 0 -o "${#snpEff_role[@]}" -gt 0; then
	
		# If no "ANN" exists, throw an error!
	
		EXTRA_CMD=cat
		if test "$snpEff_nowarn" = "false"; then
			EXTRA_CMD="grep '\|\$'"
		fi
	
		vcf-query $LOCALFN -f "%CHROM\t%POS\t%INFO/ANN\n" |  awk -F '\t|,' '{for(i=3;i<=NF;i++){ if($i != ".") {print $1 "\t" $2 "\t" $i}}}' | eval $EXTRA_CMD | tee snpeff_anno | wc -l
    
		for i in "${!snpEff_mod[@]}"; do echo "${snpEff_mod[$i]}"; done | tee snpeff_mod_fn | wc -l
		for i in "${!snpEff_role[@]}"; do echo "${snpEff_role[$i]}" | sed 's/ (\*)$//'; done | tee snpeff_role_fn | wc -l
		
		awk -F'\t|\|' ' FILENAME==ARGV[1]{mod[$0]} FILENAME==ARGV[2]{anno[$0]} FILENAME==ARGV[3]{ toprint=0; split($4, annovals, "&"); for(v in annovals){toprint += (annovals[v] in anno)};	split($5, modvals, "&"); for(v in modvals){toprint += (modvals[v] in mod)}; if(toprint != 0){print $1 "\t" $2} }' snpeff_mod_fn snpeff_role_fn snpeff_anno | uniq | tee snpeff_pass | wc -l
    fi
    
    if [[ "$clinvar_level" ]] || [[ "$dbnsfp_numpred" && "$dbnsfp_numpred" -gt 0 && "${#dbnsfp_preduse[@]}" -gt 0 ]] ; then
    
    	# If no dbNSFP exists, throw an error!
    
    	# If # of predictors to use is > # of predictors avail, set to # of predictors avail.
    	if test "$dbnsfp_numpred" -gt "${#dbnsfp_preduse[@]}"; then
    		dbnsfp_numpred="${#dbnsfp_preduse[@]}"
    	fi
    	
		vcf-query $LOCALFN -f "%CHROM\t%POS\t%INFO/dbNSFP\n" |  awk -F '\t|,' '{for(i=3;i<=NF;i++){ if($i != ".") {print $1 "\t" $2 "\t" $i}}}' > dbnsfp_anno
    		
       	for i in "${!dbnsfp_preduse[@]}"; do echo "${dbnsfp_preduse[$i]}" ; done > dbnsfp_preds
       	
       	# get the column numbers for the specific dbnsfp predictors that I want to use
       	tabix -h $LOCALFN 1:1-1 | grep '^##INFO=<ID=dbNSFP' | awk -F '|' 'NR==FNR{use[$0]} {for (i=2;i<=NF;i++){if($i in use){ print $i "\t" i}}}' dbnsfp_preds - > dbnsfp_predcols
       	
       	touch dbnsfp_pass
       	
		if [[ "$dbnsfp_numpred" && "$dbnsfp_numpred" -gt 0 && "${#dbnsfp_preduse[@]}" -gt 0 ]] ; then
 	
		   	# set the "damaging" predictions used by dbNSFP
		   	# all of the following use "D" to signify damaging
		   	for pred in SIFT LRT FATHMM MetaSVM MetaLR PROVEAN Polyphen2_HDIV Polyphen2_HVAR MutationTaster; do
		   		echo -e "$pred\tD"
		   	done > dbnsfp_predvals
		   	
		   	# these also use "P"
		   	for pred in Polyphen2_HDIV Polyphen2_HVAR; do
		   		echo -e "$pred\tP"
		   	done >> dbnsfp_predvals
		   	
		   	#Mutationtaster also uses "A"
		   	echo -e "MutationTaster\tA" >> dbnsfp_predvals
		   	
		   	#MutationAssessor is the weirdo, using H or M
		   	echo -e "MutationAssessor\tM" >> dbnsfp_predvals
		   	echo -e "MutationAssessor\tH" >> dbnsfp_predvals       	
			
			# OK, now we need to build our AWK statement using column numbers
			AWK_STR=$(while read posline; do
				colnum=$(echo "$posline" | cut -f2)
				pred=$(echo "$posline" | cut -f1)
				
				echo "annod=0; split(\$$((colnum + 2)), pvals, \"&\"); for (v in pvals){ annod += ((\"$pred\",pvals[v]) in delvals)}; toprint += (annod > 0);"
			
			done < dbnsfp_predcols)
			
			echo "AWK String: '$AWK_STR'"
			
			echo "Final awk command: 'NR==FNR{delvals[\$1,\$2]} NR!=FNR {toprint=0; $AWK_STR if(toprint >= $dbnsfp_numpred ){print \$1 \"\\t\" \$2} }'"
			
			awk -F '\t|\|' "NR==FNR{delvals[\$1,\$2]} NR!=FNR {toprint=0; $AWK_STR if(toprint >= $dbnsfp_numpred ){print \$1 \"\\t\" \$2} }" dbnsfp_predvals dbnsfp_anno | uniq | tee -a dbnsfp_pass | wc -l
			
    	fi
    	
    	#also get the clinvar columns as well
    	
    	if [[ "$clinvar_level" ]] ; then
    		cv_col=$(tabix -h $LOCALFN 1:1-1 | grep '^##INFO=<ID=dbNSFP' | tr '|' '\n' | grep -n clinvar_clnsig | cut -d: -f1)
    		
    		if test "$cv_col"; then
    		
	    		awk -F '\t|\|' "{toprint=0; split(\$$((cv_col + 2)), pvals, \"&\"); for (v in pvals){ toprint +=(pvals[v] >= $clinvar_level)}; if(toprint>0){ print \$1 \"\\t\" \$2 }}" dbnsfp_anno | uniq | tee -a dbnsfp_pass | wc -l
	    	fi
    	fi    	
    fi
    
    # Check for clinvar annotations here
    if test "$clinvar_pred" -o "$clinvar_review" -o "$clinvar_excl"; then
    	# TODO: throw an error if no clinvar annotations!
    	
    	vcf-query $LOCALFN -f "%CHROM\t%POS\t%INFO/CLINVAR\n" |  awk -F '\t|,' '{for(i=3;i<=NF;i++){ if($i != ".") {print $1 "\t" $2 "\t" $i}}}' > clinvar_anno
    	
    	# Since these will be "AND"-ed, we can just name them "clinvar_pred_pass" and "clinvar_rev_pass", and it's  automatically happen
    	#if test "$clinvar_pred" -o "$clinvar_excl"; then
    		
    		for i in "${!clinvar_pred[@]}"; do echo "${clinvar_pred[$i]}"; done | tee clinvar_pred_fn | wc -l
    		for i in "${!clinvar_excl[@]}"; do echo "${clinvar_excl[$i]}"; done | tee clinvar_excl_fn | wc -l
	    	for i in "${!clinvar_review[@]}"; do echo "${clinvar_review[$i]}"; done | tee clinvar_rev_fn | wc -l
    		
    		# CLINVAR prediction is hard-coded column 2!
    		awk -F'\t|\|' ' BEGIN{predlen=0; revlen=0} FILENAME==ARGV[1]{predlen+=1; pred[$0]} FILENAME==ARGV[2]{excl[$0]} FILENAME==ARGV[3]{revlen+=1; rev[$0]} FILENAME==ARGV[4]{toprint=0; toexcl=0; revpass=0; split($4, predvals, "&"); for(v in predvals){toprint += (predlen==0 || predvals[v] in pred); toexcl+=(predvals[v] in excl)};  split($5, revvals, "&"); for(v in revvals){revpass += (revlen==0 || revvals[v] in rev)}; if(toprint != 0 && revpass !=0 && toexcl==0){print $1 "\t" $2} }' clinvar_pred_fn clinvar_excl_fn clinvar_rev_fn clinvar_anno | uniq | tee clinvar_pred_pass | wc -l
    		
    	#fi
    	
    	#if test "$clinvar_review"; then
	    #	for i in "${!clinvar_review[@]}"; do echo "${clinvar_review[$i]}"; done | tee clinvar_rev_fn | wc -l
    			
    		# CLINVAR prediction is hard-coded column 2!
    	#	awk -F'\t|\|' ' NR==FNR{rev[$0]} NR!=FNR{toprint=0; split($5, revvals, "&"); for(v in revvals){toprint += (revvals[v] in rev)}; if(toprint != 0){print $1 "\t" $2} }' clinvar_rev_fn clinvar_anno | uniq | tee clinvar_rev_pass | wc -l
    	
    	#fi
    	
    fi
    
    fn_list=( $(ls *_pass) )
    
    FINAL_PASS=$(mktemp)
    
    if test "${#fn_list[@]}" -eq 0; then
    	dx-jobutil-report-error "ERROR: No LOF filtering done!  Would return entire VCF!"
    elif test "${#fn_list[@]}" -eq 1; then
    	sort -u -t'\0' "${fn_list[0]}" | tee $FINAL_PASS | wc -l
    else
    	TMP_PASS="${fn_list[0]}"
    	for i in $(seq 2 "${#fn_list[@]}"); do
    		TP2=$(mktemp)
    		comm -12 <(sort -u -t'\0' $TMP_PASS) <(sort -u -t'\0' "${fn_list[ $(( i - 1 )) ]}") | tee $TP2 | wc -l
    		TMP_PASS=$TP2
    	done
    	FINAL_PASS=$TMP_PASS
    fi
    
    # get the headers; I KNOW CHROM 1, POS 1 is NOT in the VCF!
    tabix -h $LOCALFN 1:1-1 > $OUTDIR/$prefix.vcf
    
    # OK, now take the data in $FINAL_PASS and output only the lines in the VCF file that match that CHROM/POS pair (as well as the header lines)
    for CHR in $(tabix -l $LOCALFN); do
    	join -t$'\t' -j 2 -o '1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8' <(tabix $LOCALFN $CHR | sort -t$'\t' -k2,2) <(grep "^$CHR\W" $FINAL_PASS | sort -t$'\t' -k2,2) | sort -t$'\t' -k2,2n
    done >> $OUTDIR/$prefix.vcf 
        
 	# and bgzip and tabix
 	bgzip $OUTDIR/$prefix.vcf
 	tabix -p vcf $OUTDIR/$prefix.vcf.gz
 	
 	# and upload... we're done!   
    	
    vcf_out=$(dx upload $OUTDIR/$prefix.vcf.gz --brief)
    vcfidx_out=$(dx upload $OUTDIR/$prefix.vcf.gz.tbi --brief)

    dx-jobutil-add-output vcf_out "$vcf_out" --class=file
    dx-jobutil-add-output vcfidx_out "$vcfidx_out" --class=file
}
