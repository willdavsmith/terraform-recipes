

eksctl create cluster \
  --name willsmith-ue-cluster-15261 \
  --region us-west-2 \
  --version 1.29 \
  --nodegroup-name ng-default \
  --node-type t3.medium \
  --nodes 1 \
  --managed \
  --tags \
    owner=willsmith
