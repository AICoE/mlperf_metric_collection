#!/bin/sh

function get_pod_run {
  #TODO(spryor) should add a check to exit on failed pod run
  while ! oc -n mlperf get pods 2>/dev/null | grep "${1}" | grep benchmark | grep Completed &>/dev/null; do
    sleep 5
  done

  echo $(oc -n mlperf get pods -o json | jq -r '.items[].metadata.name' | grep "${1}" | grep benchmark)
}

function add_json_element {
  echo $(echo "${1}" | jq -c ". += {\"${2}\": \"${3}\"}")
}

function extract_step_ips {
  echo "$(echo ${1} | sed 's/.*images\/sec: *\([0-9]\+\.[0-9]\+\).*/\1/')"
}

function extract_step_num {
  echo "$(echo ${1} | sed 's/\([0-9]\+\).*/\1/')"
}

function extract_step_loss {
  echo "$(echo ${1} | sed 's/.*\([0-9]\+\.[0-9]\+\)$/\1/')"
}

function json_to_prom_tags {
  echo "{$(echo ${1} | jq -cr 'keys_unsorted[] as $k | "\($k)=\"\(.[$k])\""' | sed ':a;N;$!ba;s/\n/,/g')}"
}

function extract_tag {
  echo "${logdata}" | grep "${1}" | sed "s/${1} *\(.*\)/\1/" | sed 's/ //'
}

function reformat_json_metrics {
  IFS=$'\n'
  for value in $(echo ${1} | jq -r '.values[] | .[]' | sed '$!N;s/\n/ /' | sed 's/\(.*\) \(.*\)/\2 \1/'); do
  echo "$(echo ${1} | jq -r '.metric.__name__')$(json_to_prom_tags $(add_json_element ${metric_tags} 'timestamp' $(echo ${value} | cut -d' ' -f2))) $(echo ${value} | cut -d' ' -f1)"
  done
}

# Parse incoming pipelinerun name
pipeline_tag="$(echo ${1} | sed 's/.*tf-cnn-pipeline-4x-run-\(.*\)\( \|$\).*/\1/')"
# TODO(spryor): make sure we passed the right item

IFS=$'\n'

pipeline_run="tf-cnn-pipeline-4x-run-${pipeline_tag}"

pod="$(get_pod_run ${pipeline_run})"

metrics=()

# TODO(spryor): update the name
logdata="$(oc -n mlperf logs ${pod} -c step-run | grep -A100 'TensorFlow:')"
# TODO(spryor): add in a check to make sure it's got the dataz

metric_tags="{\"pipeline_run\":\"${pipeline_run}\",\"model\":\"$(extract_tag 'Model:')\",\"dataset\":\"$(extract_tag 'Dataset:')\",\"devices\":\"cpu\"}"

steps=( $(echo "${logdata}" | grep -A11 Step | tail -11) )

metrics+=( "mlperf_benchmark:tensorflow_version$(json_to_prom_tags ${metric_tags}) $(extract_tag 'TensorFlow:')" )
for step in ${steps[@]}; do
  metrics+=( "mlperf_benchmark:images_per_second$(json_to_prom_tags $(add_json_element ${metric_tags} 'step' "$(extract_step_num ${step})")) $(extract_step_ips ${step})" )
  metrics+=( "mlperf_benchmark:loss$(json_to_prom_tags $(add_json_element ${metric_tags} 'step' "$(extract_step_num ${step})")) $(extract_step_loss ${step})" )
done

cpu_query="curl -X POST \"localhost:9090/api/v1/query_range?start=$(date -d'2 hours ago' +%s)&end=$(date +%s)&step=10\" -d 'query=node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate{namespace=\"mlperf\", pod=\"${pod}\", container=\"step-run\"}'"

cpu_metrics="$(oc -n openshift-monitoring exec prometheus-k8s-0 -it bash <<< ${cpu_query} 2>/dev/null | jq -c '.data.result[]')"

mem_query_rss="curl -X POST \"localhost:9090/api/v1/query_range?start=$(date -d'2 hours ago' +%s)&end=$(date +%s)&step=10\" -d 'query=container_memory_rss{namespace=\"mlperf\",pod=\"${pod}\",container=\"step-run\"}'"
mem_query_cache="curl -X POST \"localhost:9090/api/v1/query_range?start=$(date -d'2 hours ago' +%s)&end=$(date +%s)&step=10\" -d 'query=container_memory_cache{namespace=\"mlperf\",pod=\"${pod}\",container=\"step-run\"}'"
mem_query_swap="curl -X POST \"localhost:9090/api/v1/query_range?start=$(date -d'2 hours ago' +%s)&end=$(date +%s)&step=10\" -d 'query=container_memory_swap{namespace=\"mlperf\",pod=\"${pod}\",container=\"step-run\"}'"

mem_metrics_rss="$(oc -n openshift-monitoring exec prometheus-k8s-0 -it bash <<< ${mem_query_rss} 2>/dev/null | jq -c '.data.result[]')"
mem_metrics_cache="$(oc -n openshift-monitoring exec prometheus-k8s-0 -it bash <<< ${mem_query_cache} 2>/dev/null | jq -c '.data.result[]')"
mem_metrics_swap="$(oc -n openshift-monitoring exec prometheus-k8s-0 -it bash <<< ${mem_query_swap} 2>/dev/null | jq -c '.data.result[]')"

pushgw_addr="localhost:9091"
curl -XPOST --data-binary @- 'localhost:9091/metrics/job/mlperf_benchmark' <<< "$(for metric in "${metrics[@]}"; do echo ${metric}; done)"
curl -XPOST --data-binary @- 'localhost:9091/metrics/job/mlperf_benchmark' <<< $(reformat_json_metrics "${cpu_metrics}")
curl -XPOST --data-binary @- 'localhost:9091/metrics/job/mlperf_benchmark' <<< $(reformat_json_metrics "${mem_metrics_rss}")
curl -XPOST --data-binary @- 'localhost:9091/metrics/job/mlperf_benchmark' <<< $(reformat_json_metrics "${mem_metrics_cache}")
curl -XPOST --data-binary @- 'localhost:9091/metrics/job/mlperf_benchmark' <<< $(reformat_json_metrics "${mem_metrics_swap}")
