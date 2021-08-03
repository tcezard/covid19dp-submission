process download_snapshot {
    input:
    val flag from true

    output:
    val true into download_snapshot_success
    
    script:
    """
    export PYTHONPATH="$params.app.python.script_path"
    ($params.app.python.interpreter \
        -m steps.download_snapshot \
        --download-url $params.submission.download_url \
        --snapshot-name $params.submission.snapshot_name \
        --download-target-dir $params.submission.download_target_dir \
    ) >> $params.submission.log_dir/download_snapshot.log 2>&1
    """
}

process validate_vcfs {
    Channel.fromPath("$params.submission.download_file_list").splitCsv(header:false).map(row -> row[0]).set{vcf_file_list}
    
    input:
    val flag from download_snapshot_success
    val vcf_file from vcf_file_list
    
    output:
    val true into validate_vcfs_success
    
    script:
    """
    export PYTHONPATH="$params.app.python.script_path"
    ($params.app.python.interpreter \
        -m steps.run_vcf_validator \
        --vcf-file $params.submission.download_target_dir/$vcf_file \
        --validator-binary $params.app.validator_binary \
        --output-dir $params.submission.validation_dir \
    ) >> $params.submission.log_dir/validate_vcfs.log 2>&1
    """
}

process bgzip_and_index {
    Channel.fromPath("$params.submission.download_file_list").splitCsv(header:false).map(row -> row[0]).set{vcf_file_list}
    
    input:
    val flag from validate_vcfs_success.collect()
    val vcf_file from vcf_file_list
    
    output:
    val true into bgzip_and_index_success
    
    script:
    """
    export PYTHONPATH="$params.app.python.script_path"
    ($params.app.python.interpreter \
        -m steps.bgzip_and_index_vcf \
        --vcf-file $params.submission.download_target_dir/$vcf_file \
        --bcftools-binary $params.app.bcftools_binary \
    ) >> $params.submission.log_dir/bgzip_and_index_vcfs.log 2>&1
    """
}

process vertical_concat {
    input:
    val flag from bgzip_and_index_success.collect()
    
    output:
    val true into vertical_concat_success
    
    script:
    """
    export PYTHONPATH="$params.app.python.script_path"
    ($params.app.python.interpreter \
        -m steps.vcf_vertical_concat.run_vcf_vertical_concat_pipeline \
        --toplevel-vcf-dir $params.submission.download_target_dir \
        --concat-processing-dir $params.submission.concat_processing_dir \
        --concat-chunk-size $params.submission.concat_chunk_size \
        --bcftools-binary $params.app.bcftools_binary \
        --nextflow-binary $params.app.nextflow_binary \
        --nextflow-config-file $params.app.nextflow_config_file \
    ) >> $params.submission.log_dir/vertical_concat.log 2>&1
    """
}

process accession_vcf {
    clusterOptions "-g /accession/$params.app.accessioning_instance"
    
    input:
    val flag from vertical_concat_success
    
    output:
    val true into accession_vcf_success
    
    script:
    //Accessioning properties file passed via command line should already be populated with project and assembly accessions
    """
    export PYTHONPATH="$params.app.python.script_path"
    ($params.app.python.interpreter \
        -m steps.accession_vcf \
        --vcf-file $params.submission.concat_result_file \
        --accessioning-jar-file $params.app.accessioning_jar_file \
        --accessioning-properties-file $params.app.accessioning_properties_file \
        --accessioning-instance $params.app.accessioning_instance \
        --output-vcf-file $params.submission.accession_output_file \
        --bcftools-binary $params.app.bcftools_binary \
    )  >> $params.submission.log_dir/accession_vcf.log 2>&1
    """
}

process sync_accessions_to_public_ftp {    
    input:
    val flag from accession_vcf_success
    
    output:
    val true into sync_accessions_to_public_ftp_success
    
    script:
    """
    (rsync -av $params.submission.accession_output_dir/* $params.submission.ftp_project_dir) \
    >> $params.submission.log_dir/sync_accessions_to_public_ftp.log 2>&1
    """
}

process cluster_assembly {
    input:
    val flag from accession_vcf_success
    
    output:
    val true into cluster_assembly_success
    
    script:
    //Clustering properties file passed via command line should already be populated with project and assembly accessions
    """
    export PYTHONPATH="$params.app.python.script_path"
    ($params.app.python.interpreter \
        -m steps.cluster_assembly \
        --clustering-jar-file $params.app.clustering_jar_file \
        --clustering-properties-file $params.app.clustering_properties_file \
        --accessioning-instance $params.app.accessioning_instance \
    )  >> $params.submission.log_dir/cluster_assembly.log 2>&1
    """
}
