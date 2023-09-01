date
CWD=$(dirname "$0")
kubectl create ns kbench-deployment-namespace 2>/dev/null
kubectl create -f $CWD/deployment.yaml  2>/dev/null
count=0
while [ $count -lt $PODS ]
do
	sleep 2
	count=$(kubectl get pods -n kbench-deployment-namespace 2>/dev/null | grep "1/1" | wc -l)
	echo "Current : $count"
	date
done


echo -n "Starting deletion "
date
kubectl delete -f $CWD/deployment.yaml  2>/dev/null
while [ $count -gt 0 ]
do
	sleep 2
	count=$(kubectl get pods -n kbench-deployment-namespace 2>/dev/null | grep "1/1" | wc -l)
	echo "Current : $count"
	date
done

kubectl delete ns kbench-deployment-namespace 2>/dev/null
echo -n "Deletion done"
date
