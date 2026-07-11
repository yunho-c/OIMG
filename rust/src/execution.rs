use std::path::{Path, PathBuf};

use slimg_core::Format;
use slimg_exec::{
    classify_format, plan_tasks, BatchExecutor, ExecutionMode, TaskSpec, WorkloadClass,
};

use crate::codec::parse_format;
use crate::convert;
use crate::error::{Result, SlimgBridgeError};
use crate::fs::to_path_buf;
use crate::types::{
    BatchItemResult, BatchProcessRequest, ConvertOptions, CropOptions, ExtendOptions,
    ImageOperation, OptimizeOptions, ProcessFileBatchRequest, ProcessFileRequest, ResizeOptions,
};

pub(crate) struct BatchExecutionOutcome {
    pub results: Vec<BatchItemResult>,
    pub canceled: bool,
}

#[derive(Debug)]
pub(crate) struct ExecutionWorkItem {
    input_path: String,
    exec: ExecutionExec,
}

#[derive(Debug)]
enum ExecutionExec {
    Path {
        input_path: String,
        output_dir: Option<PathBuf>,
        overwrite: bool,
        operation: ImageOperation,
    },
    Request {
        request: ProcessFileRequest,
    },
}

pub(crate) fn build_work_items_for_process_files(
    request: BatchProcessRequest,
) -> Result<Vec<ExecutionWorkItem>> {
    if request.input_paths.is_empty() {
        return Err(SlimgBridgeError::invalid_request(
            "input_paths must contain at least one file",
        ));
    }

    let output_dir = request
        .output_dir
        .as_deref()
        .map(|value| to_path_buf(value, "output_dir"))
        .transpose()?;

    Ok(request
        .input_paths
        .into_iter()
        .map(|input_path| ExecutionWorkItem {
            input_path: input_path.clone(),
            exec: ExecutionExec::Path {
                input_path,
                output_dir: output_dir.clone(),
                overwrite: request.overwrite,
                operation: request.operation.clone(),
            },
        })
        .collect())
}

pub(crate) fn build_work_items_for_process_file_batch(
    request: ProcessFileBatchRequest,
) -> Result<Vec<ExecutionWorkItem>> {
    if request.requests.is_empty() {
        return Err(SlimgBridgeError::invalid_request(
            "requests must contain at least one file request",
        ));
    }

    Ok(request
        .requests
        .into_iter()
        .map(|request| ExecutionWorkItem {
            input_path: request.input_path.clone(),
            exec: ExecutionExec::Request { request },
        })
        .collect())
}

pub(crate) fn execute_batch_items(
    items: Vec<ExecutionWorkItem>,
    continue_on_error: bool,
) -> Result<Vec<BatchItemResult>> {
    Ok(
        execute_batch_items_with_events(items, continue_on_error, || false, |_| {}, |_| {})?
            .results,
    )
}

pub(crate) fn execute_batch_items_with_events<IsCancelled, OnStarted, OnFinished>(
    items: Vec<ExecutionWorkItem>,
    continue_on_error: bool,
    is_cancelled: IsCancelled,
    mut on_started: OnStarted,
    mut on_finished: OnFinished,
) -> Result<BatchExecutionOutcome>
where
    IsCancelled: Fn() -> bool,
    OnStarted: FnMut(&str),
    OnFinished: FnMut(&BatchItemResult),
{
    if !continue_on_error {
        return execute_serial(items, is_cancelled, &mut on_started, &mut on_finished);
    }

    let input_paths = items
        .iter()
        .map(|item| item.input_path.clone())
        .collect::<Vec<_>>();
    let task_specs = items
        .into_iter()
        .map(|item| {
            let workload_class = classify_work_item(&item)?;
            Ok(TaskSpec {
                input: item,
                workload_class,
            })
        })
        .collect::<Result<Vec<_>>>()?;

    let plan = plan_tasks(ExecutionMode::BalancedDesktop, task_specs);
    let report = BatchExecutor::execute(
        plan,
        is_cancelled,
        |index| on_started(input_paths[index].as_str()),
        |_, result| on_finished(result),
        |item, thread_budget| batch_item_from_work_item(item, Some(thread_budget)),
    );

    Ok(BatchExecutionOutcome {
        results: report.results.into_iter().flatten().collect(),
        canceled: report.canceled,
    })
}

fn execute_serial<IsCancelled, OnStarted, OnFinished>(
    items: Vec<ExecutionWorkItem>,
    is_cancelled: IsCancelled,
    on_started: &mut OnStarted,
    on_finished: &mut OnFinished,
) -> Result<BatchExecutionOutcome>
where
    IsCancelled: Fn() -> bool,
    OnStarted: FnMut(&str),
    OnFinished: FnMut(&BatchItemResult),
{
    let mut results = Vec::with_capacity(items.len());
    let mut failed = false;

    for item in items {
        if is_cancelled() {
            return Ok(BatchExecutionOutcome {
                results,
                canceled: true,
            });
        }

        on_started(&item.input_path);
        let result = if failed {
            BatchItemResult {
                input_path: item.input_path.clone(),
                success: false,
                result: None,
                error: Some(SlimgBridgeError::skipped_after_failure(&item.input_path)),
            }
        } else {
            batch_item_from_work_item(item, None)
        };

        if !result.success {
            failed = true;
        }

        on_finished(&result);
        results.push(result);
    }

    Ok(BatchExecutionOutcome {
        results,
        canceled: false,
    })
}

fn batch_item_from_work_item(item: ExecutionWorkItem, threads: Option<usize>) -> BatchItemResult {
    match item.exec {
        ExecutionExec::Path {
            input_path,
            output_dir,
            overwrite,
            operation,
        } => match convert::process_file_path_with_threads(
            input_path.clone(),
            None,
            output_dir,
            overwrite,
            operation,
            threads,
        ) {
            Ok(result) => BatchItemResult {
                input_path,
                success: true,
                result: Some(result),
                error: None,
            },
            Err(error) => BatchItemResult {
                input_path,
                success: false,
                result: None,
                error: Some(error),
            },
        },
        ExecutionExec::Request { request } => {
            let input_path = request.input_path.clone();
            match convert::process_file_request_with_threads(request, threads) {
                Ok(result) => BatchItemResult {
                    input_path,
                    success: true,
                    result: Some(result),
                    error: None,
                },
                Err(error) => BatchItemResult {
                    input_path,
                    success: false,
                    result: None,
                    error: Some(error),
                },
            }
        }
    }
}

fn classify_work_item(item: &ExecutionWorkItem) -> Result<WorkloadClass> {
    let (input_path, operation) = match &item.exec {
        ExecutionExec::Path {
            input_path,
            operation,
            ..
        } => (input_path.as_str(), operation),
        ExecutionExec::Request { request } => (request.input_path.as_str(), &request.operation),
    };

    Ok(infer_target_format(input_path, operation)?
        .map(classify_format)
        .unwrap_or(WorkloadClass::SingleThreadDominant))
}

fn infer_target_format(input_path: &str, operation: &ImageOperation) -> Result<Option<Format>> {
    match operation {
        ImageOperation::Convert(ConvertOptions { target_format, .. }) => {
            Ok(Some(parse_format(target_format)?))
        }
        ImageOperation::Optimize(OptimizeOptions { .. }) => {
            Ok(Format::from_extension(Path::new(input_path)))
        }
        ImageOperation::Resize(ResizeOptions { target_format, .. }) => {
            infer_optional_target_format(input_path, target_format.as_deref())
        }
        ImageOperation::Crop(CropOptions { target_format, .. }) => {
            infer_optional_target_format(input_path, target_format.as_deref())
        }
        ImageOperation::Extend(ExtendOptions { target_format, .. }) => {
            infer_optional_target_format(input_path, target_format.as_deref())
        }
    }
}

fn infer_optional_target_format(
    input_path: &str,
    target_format: Option<&str>,
) -> Result<Option<Format>> {
    match target_format {
        Some(value) => Ok(Some(parse_format(value)?)),
        None => Ok(Format::from_extension(Path::new(input_path))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{
        BatchProcessRequest, ConvertOptions, ImageOperation, OptimizeOptions, ProcessFileRequest,
    };

    #[test]
    fn classify_convert_to_avif_as_threaded() {
        let item = build_work_items_for_process_file_batch(ProcessFileBatchRequest {
            requests: vec![ProcessFileRequest {
                input_path: "/tmp/example.png".to_string(),
                output_path: None,
                overwrite: true,
                preserve_file_dates: false,
                preserve_exif: false,
                color_profile_mode: crate::types::ColorProfileMode::Preserve,
                operation: ImageOperation::Convert(ConvertOptions {
                    target_format: "avif".to_string(),
                    quality: 80,
                    effort: None,
                    png_palette: None,
                }),
            }],
            continue_on_error: true,
        })
        .unwrap()
        .remove(0);

        assert_eq!(
            classify_work_item(&item).unwrap(),
            WorkloadClass::InternallyThreaded
        );
    }

    #[test]
    fn classify_optimize_unknown_extension_as_single_threaded() {
        let item = build_work_items_for_process_file_batch(ProcessFileBatchRequest {
            requests: vec![ProcessFileRequest {
                input_path: "/tmp/example.unknown".to_string(),
                output_path: None,
                overwrite: true,
                preserve_file_dates: false,
                preserve_exif: false,
                color_profile_mode: crate::types::ColorProfileMode::Preserve,
                operation: ImageOperation::Optimize(OptimizeOptions {
                    quality: 80,
                    effort: None,
                    png_palette: None,
                    write_only_if_smaller: true,
                }),
            }],
            continue_on_error: true,
        })
        .unwrap()
        .remove(0);

        assert_eq!(
            classify_work_item(&item).unwrap(),
            WorkloadClass::SingleThreadDominant
        );
    }

    #[test]
    fn build_work_items_for_process_files_validates_output_dir() {
        let result = build_work_items_for_process_files(BatchProcessRequest {
            input_paths: vec!["/tmp/example.png".to_string()],
            output_dir: Some(String::new()),
            overwrite: true,
            operation: ImageOperation::Optimize(OptimizeOptions {
                quality: 80,
                effort: None,
                png_palette: None,
                write_only_if_smaller: true,
            }),
            continue_on_error: true,
        });

        assert!(matches!(
            result,
            Err(SlimgBridgeError::InvalidRequest { .. })
        ));
    }
}
