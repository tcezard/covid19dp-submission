import glob
import os
import shutil

from covid19dp_submission.steps.bgzip_and_index_vcf import bgzip_and_index
from covid19dp_submission.steps.download_snapshot import download_snapshot
from covid19dp_submission.steps.vcf_vertical_concat.run_vcf_vertical_concat_pipeline \
    import run_vcf_vertical_concat_pipeline, get_output_vcf_file_name
from covid19dp_submission import ROOT_DIR
from ebi_eva_common_pyutils.command_utils import run_command_with_output
from unittest import TestCase


class TestVCFVerticalConcat(TestCase):
    resources_folder = os.path.join(ROOT_DIR, 'tests', 'resources')
    download_folder = os.path.join(resources_folder, 'download_snapshot')
    download_target_dir = os.path.join(download_folder, '30_eva_valid', '2021_07_23_test_snapshot')
    processing_dir = os.path.join(resources_folder, 'processing_dir')
    download_url = "file:///" + os.path.join(resources_folder, 'vcf_files', '2021_07_23_test_snapshot.tar.gz')

    def setUp(self) -> None:
        shutil.rmtree(self.download_folder, ignore_errors=True)
        shutil.rmtree(self.processing_dir, ignore_errors=True)

    def tearDown(self) -> None:
        shutil.rmtree(self.download_folder, ignore_errors=True)
        shutil.rmtree(self.processing_dir, ignore_errors=True)

    # Tests require nextflow and bcftools installed locally and in PATH
    def test_concat_uninterrupted(self):
        download_target_dir = download_snapshot(download_url=self.download_url, snapshot_name=None,
                                                download_target_dir=self.download_target_dir)
        for vcf_file in glob.glob(f"{download_target_dir}/*.vcf.gz"):
            bgzip_and_index(vcf_file, "bcftools")
        #   s0.vcf.gz   s1.vcf.gz   s2.vcf.gz   s3.vcf.gz   s4.vcf.gz
        #       \           /           \           /
        #        s01.vcf.gz               s23.vcf.gz        s4.vcf.gz       <-------- Stage 0
        #               \                      /
        #                \                   /
        #                 \                /
        #                   s0123.vcf.gz                    s4.vcf.gz       <-------- Stage 1
        #                           \                       /
        #                            \                    /
        #                             \                 /
        #                                 Final_merged                      <-------- Stage 2
        run_vcf_vertical_concat_pipeline(toplevel_vcf_dir=download_target_dir,
                                         concat_processing_dir=self.processing_dir,
                                         concat_chunk_size=2, bcftools_binary="bcftools",
                                         nextflow_binary="nextflow", nextflow_config_file=None, resume=False)
        stage_dirs = glob.glob(f"{self.processing_dir}/vertical_concat/stage*")
        self.assertEqual(3, len(stage_dirs))
        output_vcf_from_multi_stage_concat = get_output_vcf_file_name(concat_stage_index=2, concat_batch_index=0,
                                                                      concat_processing_dir=self.processing_dir)

        input_vcfs = sorted(glob.glob(f"{download_target_dir}/*.vcf.gz"))
        output_vcf_from_single_stage_concat = f"{self.processing_dir}/single_stage_concat_result.vcf.gz"
        run_command_with_output("Concatenate VCFs with single stage...", f"bcftools concat {' '.join(input_vcfs)} "
                                                                         f"--allow-overlaps --remove-duplicates "
                                                                         f"-O z "
                                                                         f"-o {output_vcf_from_single_stage_concat}"
                                )
        diffs = run_command_with_output("Compare outputs from single and multi-stage concat processes...",
                                        f'bash -c "diff '
                                        f'<(zcat {output_vcf_from_single_stage_concat} | grep -v ^#) '
                                        f'<(zcat {output_vcf_from_multi_stage_concat} | grep -v ^#)"',
                                        return_process_output=True)
        self.assertEqual("", diffs.strip())

        # Attempts at re-processing with the processing directory still existing should fail
        with self.assertRaises(FileExistsError) as process_dir_exists_exception:
            run_vcf_vertical_concat_pipeline(toplevel_vcf_dir=download_target_dir,
                                             concat_processing_dir=self.processing_dir,
                                             concat_chunk_size=2, bcftools_binary="bcftools",
                                             nextflow_binary="nextflow", nextflow_config_file=None, resume=False)
        self.assertEqual(process_dir_exists_exception.exception.args[0],
                         f"FAIL: Vertical concatenation processing directory: {self.processing_dir} "
                         f"already exists. Please delete that directory to re-process.")
