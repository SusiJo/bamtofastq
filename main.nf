#!/usr/bin/env nextflow
/*
========================================================================================
                         qbic-pipelines/bamtofastq
========================================================================================
 qbic-pipelines/bamtofastq Analysis Pipeline.
  An open-source analysis pipeline to convert mapped or unmapped single-end or paired-end
  reads from bam format to fastq format
 #### Homepage / Documentation
 https://github.com/qbic-pipelines/bamtofastq
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run qbic-pipelines/bamtofastq --input '*bam' -profile cfc

    Mandatory arguments:
      --input                  [file]  Path to input data, multiple files can be specified by using wildcard characters
      -profile                  [str]  Configuration profile to use. Can use multiple (comma separated)
                                       Available: conda, docker, singularity, awsbatch, test and more.

    Other options:
      --outdir                 [file]  The output directory where the results will be saved
      --chr                     [str]  Only use reads mapping to a specific chromosome/region. Has to be specified as in bam: i.e chr1, chr{1..22} (gets all reads mapping to chr1 to 22), 1, "X Y", incorrect naming will lead to a potentially silent error
      --index_files            [bool]  Index files are provided
      --samtools_collate_fast  [bool]  Uses fast mode for samtools collate in `sortExtractMapped`, `sortExtractUnmapped` and `sortExtractSingleEnd`
      --reads_in_memory         [str]  Reads to store in memory [default = '100000']. Only relevant for use with `--samtools_collate_fast`.
      --no_read_QC             [bool]  If specified, no quality control will be performed on extracted reads. Useful, if this is done anyways in the subsequent workflow
      --no_stats               [bool]  If specified, skips all quality control and stats computation, including `FastQC` on both input bam and output reads, `samtools flagstat`, `samtools idxstats`, and `samtools stats`
      --email                   [str]  Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail           [str]  Same as --email, except only send mail if the workflow is not successful
      --maxMultiqcEmailFileSize [str]  Threshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                     [str]  Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                [str]  The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion               [str]  The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
  custom_runName = workflow.runName
}

if ( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)


/*
 * Create a channel for input files
 */
if (params.input_paths){

   Channel
      .from( params.input_paths )
      .map { row -> [ row[0], file(row[1][0]), file(row[1][1])] }
      .into{ ch_idxstats;
             ch_flagstats;
             ch_stats;
             ch_input_fastqc;
             ch_processing;
       }
} else {

  if(params.index_files){ //Index files are provided

    Channel.fromFilePairs(params.input, flat:true, checkIfExists:true) { file -> file.name.replaceAll(/.bam|.bai$/,'') }
      .map { name, file1, file2 ->
            //Ensure second element in ma will be bam, and third bai
             if(file2.extension.toString() == 'bai'){
               bam = file1
               bai = file2
             }else{
               bam = file2
               bai = file1
             }
            [name, bam, bai]}       // Map: [ name, name.bam, name.bam.bai ]
      .into { ch_idxstats;
              ch_flagstats;
              ch_stats;
              ch_input_fastqc;
              ch_processing }

  } else if(!params.index_files) { //Index files need to be computed

    Channel
          .fromPath(params.input, checkIfExists: true)
          .map { file -> tuple(file.name.replaceAll(".bam",''), file) } // Map: [name, name.bam] (map bam file name w/o bam to file)
          .set { bam_files_index }

  }else{
        exit 1, "Parameter 'params.input' was not specified!\n"
  }
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release']                    = workflow.revision
summary['Run Name']                                                   = custom_runName ?: workflow.runName
summary['Input']                                                      = params.input
summary['Max Resources']                                              = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container']                    = "$workflow.containerEngine - $workflow.container"
summary['Output dir']                                                 = params.outdir
if (params.chr) summary['Only reads mapped to chr']                   = params.chr
if (params.index_files) summary['Index files available']              = params.index_files ? 'Yes': 'No'
if (params.samtools_collate_fast) summary['Collate fast']             = params.samtools_collate_fast ? 'Yes': 'No'
if (params.reads_in_memory) summary['Reads in memory']                = params.reads_in_memory ? params.reads_in_memory : ''
summary['Read QC']                                                    = params.no_read_QC ? 'No' : 'Yes'
summary['Stats']                                                      = params.no_stats ? 'No' : 'Yes'
summary['Launch dir']                                                 = workflow.launchDir
summary['Working dir']                                                = workflow.workDir
summary['Script dir']                                                 = workflow.projectDir
summary['User']                                                       = workflow.userName
if (workflow.profile == 'awsbatch') {
  summary['AWS Region']                                               = params.awsregion
  summary['AWS Queue']                                                = params.awsqueue
}
summary['Config Profile']                                             = workflow.profile
if (params.config_profile_description) summary['Config Description']  = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']      = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']          = params.config_profile_url
if (params.email || params.email_on_fail) {
  summary['E-mail Address']                                           = params.email
  summary['E-mail on failure']                                        = params.email_on_fail
  summary['MultiQC maxsize']                                          = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(26)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'qbic-pipelines-bamtofastq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'qbic-pipelines/bamtofastq Workflow Summary'
    section_href: 'https://github.com/qbic-pipelines/bamtofastq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
            if (filename.indexOf(".csv") > 0) filename
            else null
        }
    label 'process_low'


    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"
    file "*.txt"

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version &> v_fastqc.txt
    samtools --version > v_samtools.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}


/*
 * Step 0: If index_files not provided as input compute them first
 */
if(!params.index_files){
  process IndexBAM {
    tag "$name"
    label 'process_medium'

    input:
    set val(name), file(bam) from bam_files_index

    output:
    set val(name), file(bam), file("*.bai") into (ch_idxstats, ch_flagstats, ch_stats, ch_input_fastqc, ch_processing)

    when:
    !params.index_files //redundant, since the input channel only exists, if no indices are provided

    script:
    """
    samtools index ${bam}
    """
  }
}


/*
 * Step 0: Compute statistics on the input bam files
 */
process computeIdxstatsInput {
  tag "$name"
  label 'process_medium'

  input:
  set val(name), file(bam), file(bai) from ch_idxstats

  output:
  file "*.idxstats" into ch_bam_idxstat_mqc

  when:
  !params.no_stats

  script:
  """
  samtools idxstats $bam > "${bam}.idxstats"
  """
}


process computeFlagstatInput{
  tag "$name"
  label 'process_medium'

  input:
  set val(name), file(bam), file(bai) from ch_flagstats

  output:
  file "*.flagstat" into ch_bam_flagstat_mqc

  when:
  !params.no_stats

  script:
  """
  samtools flagstat -@ $task.cpus ${bam} > ${bam}.flagstat
  """
}


process computeStatsInput{

  tag "$name"
  label 'process_medium'

  input:
  set val(name), file(bam), file(bai) from ch_stats

  output:
  file "*.stats" into ch_bam_stats_mqc

  when:
  !params.no_stats

  script:
  """
  samtools stats -@ $task.cpus ${bam} > ${bam}.stats
  """
}


process computeFastQCInput{
  tag "$name"
  label 'process_medium'

  input:
  set val(name), file(bam), file(bai) from ch_input_fastqc

  output:
  file "*.{zip,html}" into ch_fastqc_reports_mqc_input_bam

  when:
  !params.no_stats

  script:
  """
  fastqc --quiet --threads $task.cpus ${bam}
  """
}


// Extract reads mapping to specific chromosome(s)
if (params.chr){
  process extractReadsMappingToChromosome{
    tag "${name}.${chr_list_joined}"
    label 'process_medium'

    input:
    set val(name), file(bam), file(bai) from ch_processing

    output:
    set val("${name}.${chr_list_joined}"), file("${name}.${chr_list_joined}.bam"), file("${name}.${chr_list_joined}.bam.bai") into bam_files_check

    script:
    //If multiple chr were specified, then join space separated list for naming: chr1 chr2 -> chr1_chr2, also resolve region specification with format chr:start-end
    chr_list_joined = params.chr.split(' |-|:').size() > 1 ? params.chr.split(' |-|:').join('_') : params.chr
    """
    samtools view -hb $bam ${params.chr} -@ $task.cpus -o "${name}.${chr_list_joined}.bam"
    samtools index "${name}.${chr_list_joined}.bam"
    """
  }
} else{
  bam_files_check = ch_processing
}


/*
 * STEP 1: Check for paired-end or single-end bam
 */
process checkIfPairedEnd{
  tag "$name"
  label 'process_low'
  input:
  set val(name), file(bam), file(bai) from bam_files_check

  output:
  set val(name), file(bam), file(bai), file('*paired.txt') optional true into bam_files_paired_map_map,
                                                                              bam_files_paired_unmap_unmap,
                                                                              bam_files_paired_unmap_map,
                                                                              bam_files_paired_map_unmap
  set val(name), file(bam), file(bai), file('*single.txt') optional true into bam_file_single_end // = is not paired end

  //Take samtools header + the first 1000 reads (to safe time, otherwise also all can be used) and check whether for
  //all, the flag for paired-end is set. Compare: https://www.biostars.org/p/178730/ .
  script:
  """
  if [ \$({ samtools view -H $bam -@ $task.cpus ; samtools view $bam -@ $task.cpus | head -n1000; } | samtools view -c -f 1  -@ $task.cpus | awk '{print \$1/1000}') = "1" ]; then
    echo 1 > ${name}.paired.txt
  else
    echo 0 > ${name}.single.txt
  fi
  """
}


/*
 * Step 2a: Handle paired-end bams
 */
process pairedEndMapMap{
  tag "$name"
  label 'process_low'
  input:
  set val(name), file(bam), file(bai), file(txt) from bam_files_paired_map_map

  output:
  set val(name), file( '*.map_map.bam') into map_map_bam

  when:
  txt.exists()

  script:
  """
  samtools view -b1 -f1 -F12 $bam -@ $task.cpus -o ${name}.map_map.bam   
  """
}

process pairedEndUnmapUnmap{
  tag "$name"
  label 'process_low'
  input:
  set val(name), file(bam), file(bai), file(txt) from bam_files_paired_unmap_unmap

  output:
  set val(name), file('*.unmap_unmap.bam') into unmap_unmap_bam

  when:
  txt.exists()

  script:
  """
  samtools view -b1 -f12 -F256 $bam -@ $task.cpus -o ${name}.unmap_unmap.bam
  """
}

process pairedEndUnmapMap{
  tag "$name"
  label 'process_low'
  input:
  set val(name), file(bam), file(bai), file(txt) from bam_files_paired_unmap_map

  output:
  set val(name), file( '*.unmap_map.bam') into unmap_map_bam

  when:
  txt.exists()

  script:
  """
  samtools view -b1 -f4 -F264 $bam -@ $task.cpus -o ${name}.unmap_map.bam
  """
}

process pairedEndMapUnmap{
  tag "$name"
  label 'process_low'
  input:
  set val(name), file(bam), file(bai), file(txt) from bam_files_paired_map_unmap

  output:
  set val(name), file( '*.map_unmap.bam') into map_unmap_bam

  when:
  txt.exists()

  script:
  """
  samtools view -b1 -f8 -F260 $bam  -@$task.cpus -o ${name}.map_unmap.bam
  """
}

unmap_unmap_bam.join(map_unmap_bam, remainder: true)
                .join(unmap_map_bam, remainder: true)
                .set{ all_unmapped_bam }

process mergeUnmapped{
  tag "$name"
  label 'process_low'
  input:
  set val(name), file(unmap_unmap), file (map_unmap),  file(unmap_map) from all_unmapped_bam

  output:
  set val(name), file('*.merged_unmapped.bam') into merged_unmapped

  script:
  """
  samtools merge ${name}.merged_unmapped.bam $unmap_unmap $map_unmap $unmap_map  -@ $task.cpus
  """
}

process sortExtractMapped{
  tag "$name"
  label 'process_medium'

  input:
  set val(name), file(all_map_bam) from map_map_bam

  output:
  set val(name), file('*_mapped.fq.gz') into reads_mapped

  script:  
  def collate_fast = params.samtools_collate_fast ? "-f -r " + params.reads_in_memory : ""
  """
  samtools collate -O -@ $task.cpus $collate_fast $all_map_bam . \
    | samtools fastq -1 ${name}_R1_mapped.fq.gz -2 ${name}_R2_mapped.fq.gz -s ${name}_mapped_singletons.fq.gz -N -@ $task.cpus
  """
}

process sortExtractUnmapped{
  label 'process_medium'
  tag "$name"

  input:
  set val(name), file(all_unmapped) from merged_unmapped

  output:
  set val(name), file('*_unmapped.fq.gz') into reads_unmapped

  script:  
  def collate_fast = params.samtools_collate_fast ? "-f -r " + params.reads_in_memory : ""
  """
  samtools collate -O -@ $task.cpus $collate_fast $all_unmapped . \
      | samtools fastq -1 ${name}_R1_unmapped.fq.gz -2 ${name}_R2_unmapped.fq.gz -s ${name}_unmapped_singletons.fq.gz -N -@ $task.cpus
  """
}

reads_mapped.join(reads_unmapped, remainder: true)
            .map{
              row -> tuple(row[0], row[1][0], row[1][1], row[2][0], row[2][1])
            }
            .set{ all_fastq }

process joinMappedAndUnmappedFastq{
  label 'process_low'
  tag "$name"
  publishDir "${params.outdir}/reads", mode: 'copy',
        saveAs: { filename ->
            if (filename.indexOf(".fq.gz") > 0) filename
            else null
        }

  input:
  set val(name), file(mapped_fq1), file(mapped_fq2), file(unmapped_fq1), file(unmapped_fq2) from all_fastq.filter{ it.size()>0 }

  output:
  set file('*1.fq.gz'), file('*2.fq.gz') into read_qc


  script:
  """
  cat $unmapped_fq1 >> $mapped_fq1
  mv $mapped_fq1 ${name}.1.fq.gz
  cat $unmapped_fq2 >> $mapped_fq2
  mv $mapped_fq2 ${name}.2.fq.gz
  """
}


process pairedEndReadsQC{
    label 'process_medium'
    tag "$read1"

    input:
    set file(read1), file(read2) from read_qc

    output:
    file "*.{zip,html}" into ch_fastqc_reports_mqc_pe

    when:
    !params.no_read_QC && !params.no_stats

    script:
    """
    fastqc --quiet --threads $task.cpus $read1 $read2
    """
}


/*
 * STEP 2b: Handle single-end bams
 */
process sortExtractSingleEnd{
    tag "$name"
    label 'process_medium'

    publishDir "${params.outdir}/reads", mode: 'copy',
        saveAs: { filename ->
            if (filename.indexOf(".fq.gz") > 0) filename
            else null
        }

    input:
    set val(name), file(bam), file(bai), file(txt) from bam_file_single_end

    output:
    set val(name), file ('*.singleton.fq.gz') into single_end_reads

    when:
    txt.exists()

    script:    
    def collate_fast = params.samtools_collate_fast ? "-f -r " + params.reads_in_memory : ""
    """
    samtools collate -O -@ $task.cpus $collate_fast $bam . \
      | samtools fastq -0 ${name}.singleton.fq.gz -N -@ $task.cpus
    """
 }


process singleEndReadQC{
    tag "$name"
    label 'process_medium'


    input:
    set val(name), file(reads) from single_end_reads

    output:
    file "*.{zip,html}" into ch_fastqc_reports_mqc_se

    when:
    !params.no_read_QC && !params.no_stats

    script:
    """
    fastqc --quiet --threads $task.cpus ${reads}
    """

}

/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'
    label 'process_low'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}

/*
 * STEP 4 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'
    label 'process_low'

    input:
    file multiqc_config from ch_multiqc_config

    file ('software_versions/*') from software_versions_yaml.collect()
    file workflow_summary from create_workflow_summary(summary)
    file flagstats from ch_bam_flagstat_mqc.collect()
    file stats from ch_bam_stats_mqc.collect()
    file idxstats from ch_bam_idxstat_mqc.collect()
    file fastqc_bam from ch_fastqc_reports_mqc_input_bam.collect().ifEmpty([])
    file fastqc_se from ch_fastqc_reports_mqc_se.collect().ifEmpty([])
    file fastqc_pe from ch_fastqc_reports_mqc_pe.collect().ifEmpty([])

    output:
    file "*multiqc_report.html"
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f -s $rtitle $rfilename $multiqc_config .
    """

}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[qbic-pipelines/bamtofastq] Successful: $workflow.runName"
    if (!workflow.success) {
      subject = "[qbic-pipelines/bamtofastq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if (workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[qbic-pipelines/bamtofastq] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[qbic-pipelines/bamtofastq] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
          if ( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[qbic-pipelines/bamtofastq] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, email_address ].execute() << email_txt
          log.info "[qbic-pipelines/bamtofastq] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if (!output_d.exists()) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}"
    }

    if (workflow.success) {
        log.info "${c_purple}[qbic-pipelines/bamtofastq]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[qbic-pipelines/bamtofastq]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  qbic-pipelines/bamtofastq v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
