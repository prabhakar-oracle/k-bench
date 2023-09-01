#! /bin/bash
#set -x

TARGET_CLUSTER="targetcluster.burst"
KUBEMARK_CLUSTER="kubemark-cluster"
NODE_BUCKETS="10 100 250 500"

function prerequisites() {
   which kubectx || (echo "kubectx not found" && return 1)
	
   kubectx | grep $KUBEMARK_CLUSTER
   if [ $? -ne 0 ]; then
	   echo "Kubemark cluster not found in kubectx context list"
	   return 1
   else 
	   kubectx $KUBEMARK_CLUSTER
	   kubectl get nodes > /dev/null 2>&1 || (echo "Could not talk to kubemark cluster" && return 2)
   fi

   kubectx | grep $TARGET_CLUSTER
   if [ $? -ne 0 ]; then
	   echo "Target cluster not found in kubectx context list"
	   return 1
   else
	   kubectx $TARGET_CLUSTER
	   kubectl get nodes > /dev/null 2>&1 || (echo "Could not talk to target cluster" && return 2)
	   nodes=$(kubectl get nodes --no-headers |wc -l)
	   if [ $nodes -ne 0 ]; then
               echo "The current node count should be zero to start the test sequence"
	       exit 3
	   fi
   fi
	
}

function generate_test_config() {
	mkdir -p $OUTDIR
	for nodecount in $NODE_BUCKETS
	do
		subdir="$OUTDIR/${nodecount}-nodes"
		mkdir -p $subdir

		PODS=25 MAX_POD_TIMEOUT=60000 envsubst <templates/pods.json > $subdir/min-pods.json
		PODS=$nodecount MAX_POD_TIMEOUT=120000 envsubst <templates/pods.json > $subdir/N-pods.json

		POD_COUNT=$(( nodecount * 100 ))
		# about 100ms per pod when pod count is high
		MAX_POD_TIMEOUT=$(( POD_COUNT * 100 ))
		if [ $MAX_POD_TIMEOUT -le 180000 ]; then
			MAX_POD_TIMEOUT=180000
		fi
		PODS=$POD_COUNT MAX_POD_TIMEOUT=$MAX_POD_TIMEOUT envsubst <templates/pods.json > $subdir/N100-pods.json

		PODS=$POD_COUNT envsubst <templates/deployment.yaml > $subdir/deployment.yaml
		PODS=$POD_COUNT CWD="\$CWD" count="\$count" envsubst <templates/test-deploy.sh > $subdir/test-deploy.sh
	done
}

function scaleup_target_cluster() {
	target_count=$1
  	kubectx $TARGET_CLUSTER	
	cur_count=$(kubectl get nodes --no-headers |wc -l)

	while [ "$cur_count" -lt "$target_count" ]
	do
		kubectx $KUBEMARK_CLUSTER
		current_hollow_pod_count=$(kubectl get rc -n kubemark hollow-node -o json | jq ".status.readyReplicas")
		new_hollow_pod_count=$(( current_hollow_pod_count + target_count - cur_count ))
		echo "Scaling up the kubemark rc to $new_hollow_pod_count"
		kubectl scale rc -n kubemark hollow-node --replicas=$new_hollow_pod_count
		sleep 15
 	 	kubectx $TARGET_CLUSTER	
	        cur_count=$(kubectl get nodes --no-headers |wc -l)
	done

	if [ "$target_count" -gt 50 ]; then 
		echo "Waiting for 30 minutes for KMI scaleup, press enter to continue right away"
		timeout 2400 read
	fi
}

function wait_for_ns_cleanup() {
	kubectl get ns |grep kbench-pod-namespace
	while [ $? -eq 0 ]
	do
		echo "Waiting for ns cleanup ($pod_count)"
		sleep 5
		kubectl get ns |grep kbench-pod-namespace
	done

	sleep 10
}
function wait_for_pod_cleanup() {
	pod_count=$(kubectl get pods -n kbench-pod-namespace|grep hollow|wc -l)
	while [ "$pod_count" -gt 0 ]
	do
		echo "Waiting for pod cleanup ($pod_count)"
		sleep 5
		pod_count=$(kubectl get pods -n kbench-pod-namespace|grep hollow | wc -l)
	done

	wait_for_ns_cleanup
}

function run_tests() {
	for nodecount in $NODE_BUCKETS
	do
		mv kbench.log kbench.log.$(date +%F_%X|tr ':' '-')
		subdir="$OUTDIR/${nodecount}-nodes"

		scaleup_target_cluster $nodecount| tee -a $subdir/output.log

 	 	kubectx $TARGET_CLUSTER	
                time kbench -benchconfig $subdir/min-pods.json | tee -a $subdir/output.log
		wait_for_pod_cleanup
                time kbench -benchconfig $subdir/N-pods.json | tee -a $subdir/output.log
		wait_for_pod_cleanup
                time kbench -benchconfig $subdir/N100-pods.json | tee -a $subdir/output.log
		wait_for_pod_cleanup
		time bash $subdir/test-deploy.sh | tee -a $subdir/output.log
		mv kbench.log $subdir/
	done
}

prerequisites || exit 1
echo "Prerequisites succeeded"
export OUTDIR="output/$(date +%F_%X|tr ':' '-')"
generate_test_config || exit 2

run_tests
