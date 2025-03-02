#!/bin/bash

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"/..

if [ -f $ROOT/hack/preview.env ]; then
    source $ROOT/hack/preview.env
fi

if [ -z "$MY_GIT_FORK_REMOTE" ]; then
    echo "Set MY_GIT_FORK_REMOTE environment to name of your fork remote"
    exit 1
fi

MY_GIT_REPO_URL=$(git ls-remote --get-url $MY_GIT_FORK_REMOTE | sed 's|^git@github.com:|https://github.com/|')
MY_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)


if echo "$MY_GIT_REPO_URL" | grep -q redhat-appstudio/infra-deployments; then
    echo "Use your fork repository for preview"
    exit 1
fi

if ! git diff --exit-code --quiet; then
    echo "Changes in working Git working tree, commit them or stash them"
    exit 1
fi

# Create preview branch for preview configuration
PREVIEW_BRANCH=preview-${MY_GIT_BRANCH}${TEST_BRANCH_ID+-$TEST_BRANCH_ID}
if git rev-parse --verify $PREVIEW_BRANCH; then
    git branch -D $PREVIEW_BRANCH
fi
git checkout -b $PREVIEW_BRANCH

# Set the domain for our rekor deployment.
# We add the modified rekor.yaml file and this will get pushed to our preview branch.
# This shouldn't ever be updated in $MY_GIT_BRANCH.
# If you know a better way to make this magic happen, contact rnester@redhat.com
domain=$( kubectl get ingresses.config.openshift.io cluster --template={{.spec.domain}} )
echo
echo "Setting rekor server domain to: $domain"
echo
sed -i "s/rekor-server.enterprise-contract-service.svc/rekor.$domain/" $ROOT/argo-cd-apps/base/enterprise-contract.yaml
git add $ROOT/argo-cd-apps/base/enterprise-contract.yaml && git commit -m "Set domain for rekor"

# reset the default repos in the development directory to be the current git repo
# this needs to be pushed to your fork to be seen by argocd
$ROOT/hack/util-set-development-repos.sh $MY_GIT_REPO_URL development $PREVIEW_BRANCH

# set the API server which SPI uses to authenticate users to empty string (by default) so that multi-cluster
# setup is not needed
$ROOT/hack/util-set-spi-api-server.sh "$SPI_API_SERVER"

# set backend route for quality dashboard for current cluster
$ROOT/hack/util-set-quality-dashboard-backend-route.sh

if [ -n "$MY_GITHUB_ORG" ]; then
    $ROOT/hack/util-set-github-org $MY_GITHUB_ORG
fi

if [ -n "$SHARED_SECRET" ] && [ -n "$SPI_TYPE" ] && [ -n "$SPI_CLIENT_ID" ] && [ -n "$SPI_CLIENT_SECRET" ]; then
    TMP_FILE=$(mktemp)
    ROUTE="https://$(oc get routes -n spi-system spi-oauth-route -o yaml -o jsonpath='{.spec.host}')"
    yq e ".sharedSecret=\"$SHARED_SECRET\"" $ROOT/components/spi/config.yaml | \
        yq e ".serviceProviders[0].type=\"$SPI_TYPE\"" - | \
        yq e ".serviceProviders[0].clientId=\"$SPI_CLIENT_ID\"" - | \
        yq e ".serviceProviders[0].clientSecret=\"$SPI_CLIENT_SECRET\"" - | \
        yq e ".baseUrl=\"$ROUTE\"" - > $TMP_FILE
    oc create -n spi-system secret generic oauth-config --from-file=config.yaml=$TMP_FILE --dry-run=client -o yaml | oc apply -f -
    echo "SPI configurared, set Authorization callback URL to $ROUTE"
    rm $TMP_FILE
fi

if [ -n "$DOCKER_IO_AUTH" ]; then
    AUTH=$(mktemp)
    # Set global pull secret
    oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}' > $AUTH
    oc registry login --registry=docker.io --auth-basic=$DOCKER_IO_AUTH --to=$AUTH
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=$AUTH
    # Set current namespace pipeline serviceaccount which is used by buildah
    oc create secret docker-registry docker-io-pull --from-file=.dockerconfigjson=$AUTH -o yaml --dry-run=client | oc apply -f-
    oc secrets link pipeline docker-io-pull
    rm $AUTH
fi

[ -n "${BUILD_SERVICE_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/build-service\")) |=.newName=\"${BUILD_SERVICE_IMAGE_REPO}\"" $ROOT/components/build/build-service/kustomization.yaml
[ -n "${BUILD_SERVICE_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/build-service\")) |=.newTag=\"${BUILD_SERVICE_IMAGE_TAG}\"" $ROOT/components/build/build-service/kustomization.yaml
[[ -n "${BUILD_SERVICE_PR_OWNER}" && "${BUILD_SERVICE_PR_SHA}" ]] && yq -i e "(.resources[] | select(. ==\"*github.com/redhat-appstudio/build-service*\")) |= \"https://github.com/${BUILD_SERVICE_PR_OWNER}/build-service/config/default?ref=${BUILD_SERVICE_PR_SHA}\"" $ROOT/components/build/build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"hacbs-jvm-operator\")) |=.newName=\"${JVM_BUILD_SERVICE_IMAGE_REPO}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"hacbs-jvm-operator\")) |=.newTag=\"${JVM_BUILD_SERVICE_IMAGE_TAG}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml
[[ -n "${JVM_BUILD_SERVICE_PR_OWNER}" && "${JVM_BUILD_SERVICE_PR_SHA}" ]] && sed -i -e "s|\(https://github.com/\)redhat-appstudio\(/jvm-build-service/.*?ref=\)\(.*\)|\1${JVM_BUILD_SERVICE_PR_OWNER}\2${JVM_BUILD_SERVICE_PR_SHA}|" -e "s|\(https://raw.githubusercontent.com/\)redhat-appstudio\(/jvm-build-service/\)[^/]*\(/.*\)|\1${JVM_BUILD_SERVICE_PR_OWNER}\2${JVM_BUILD_SERVICE_PR_SHA}\3|" $ROOT/components/build/jvm-build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"hacbs-jvm-operator\")) |=.newName=\"${JVM_BUILD_SERVICE_IMAGE_REPO}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"hacbs-jvm-operator\")) |=.newTag=\"${JVM_BUILD_SERVICE_IMAGE_TAG}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_CACHE_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"hacbs-jvm-cache\")) |=.newName=\"${JVM_BUILD_SERVICE_CACHE_IMAGE_REPO}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_CACHE_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"hacbs-jvm-cache\")) |=.newTag=\"${JVM_BUILD_SERVICE_CACHE_IMAGE_TAG}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_SIDECAR_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"run-maven-component-build\")) |=.newName=\"${JVM_BUILD_SERVICE_SIDECAR_IMAGE_REPO}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_SIDECAR_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"run-maven-component-build\")) |=.newTag=\"${JVM_BUILD_SERVICE_SIDECAR_IMAGE_TAG}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_REQPROCESSOR_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"lookup-artifact-location\")) |=.newName=\"${JVM_BUILD_SERVICE_REQPROCESSOR_IMAGE_REPO}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml
[ -n "${JVM_BUILD_SERVICE_REQPROCESSOR_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"lookup-artifact-location\")) |=.newTag=\"${JVM_BUILD_SERVICE_REQPROCESSOR_IMAGE_TAG}\"" $ROOT/components/build/jvm-build-service/kustomization.yaml

[ -n "${HAS_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/application-service\")) |=.newName=\"${HAS_IMAGE_REPO}\"" $ROOT/components/has/kustomization.yaml
[ -n "${HAS_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/application-service\")) |=.newTag=\"${HAS_IMAGE_TAG}\"" $ROOT/components/has/kustomization.yaml
[[ -n "${HAS_PR_OWNER}" && "${HAS_PR_SHA}" ]] && yq -i e "(.resources[] | select(. ==\"*github.com/redhat-appstudio/application-service*\")) |= \"https://github.com/${HAS_PR_OWNER}/application-service/config/default?ref=${HAS_PR_SHA}\"" $ROOT/components/has/kustomization.yaml
[ -n "${HAS_DEFAULT_IMAGE_REPOSITORY}" ] && yq -i e "(.spec.template.spec.containers[].env[] | select(.name ==\"IMAGE_REPOSITORY\").value) |= \"${HAS_DEFAULT_IMAGE_REPOSITORY}\"" $ROOT/components/has/manager_resources_patch.yaml
[ -n "${RELEASE_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/release-service\")) |=.newName=\"${RELEASE_IMAGE_REPO}\"" $ROOT/components/release/kustomization.yaml
[ -n "${RELEASE_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/release-service\")) |=.newTag=\"${RELEASE_IMAGE_TAG}\"" $ROOT/components/release/kustomization.yaml
[ -n "${RELEASE_RESOURCES}" ] && yq -i e "(.resources[] | select(.==\"https://github.com/redhat-appstudio/release-service/config/default?ref=*\")) |=.=\"${RELEASE_RESOURCES}\"" components/release/kustomization.yaml
[ -n "${SPI_OPERATOR_IMAGE_REPO}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/service-provider-integration-operator\")) |=.newName=\"${SPI_OPERATOR_IMAGE_REPO}\"" $ROOT/components/spi/kustomization.yaml
[ -n "${SPI_OPERATOR_IMAGE_TAG}" ] && yq -i e "(.images.[] | select(.name==\"quay.io/redhat-appstudio/service-provider-integration-operator\")) |=.newTag=\"${SPI_OPERATOR_IMAGE_TAG}\"" $ROOT/components/spi/kustomization.yaml

if ! git diff --exit-code --quiet; then
    git commit -a -m "Preview mode, do not merge into main"
    git push -f --set-upstream $MY_GIT_FORK_REMOTE $PREVIEW_BRANCH
fi

git checkout $MY_GIT_BRANCH

#set the local cluster to point to the current git repo and branch and update the path to development
$ROOT/hack/util-update-app-of-apps.sh $MY_GIT_REPO_URL development $PREVIEW_BRANCH

# trigger refresh of apps
for APP in $(kubectl get apps -n openshift-gitops -o name); do
  kubectl patch $APP -n openshift-gitops --type merge -p='{"metadata": {"annotations":{"argocd.argoproj.io/refresh": "hard"}}}'
done

# Make sure we have a tekton-chains namespace
echo "Checking to see if tekton-chains namespace exists"
while ! kubectl get namespace tekton-chains &> /dev/null; do
  echo -n .
  sleep 3
done

echo "Setting chains to use cluster rekor server: https://rekor.$domain"
kubectl patch configmap/chains-config -n tekton-chains --patch "{\"data\":{\"transparency.url\":\"https://rekor.$domain\"}}" --type=merge
# Delete the controller pod for chains to ensure that the configuration change gets picked up.
echo "Restarting chains controller"
kubectl delete pod -n tekton-chains -l app=tekton-chains-controller
# If we have a rekor namespace, we should wait for the server to be available
if kubectl get namespace enterprise-contract-service &>/dev/null; then
    kubectl delete pod -n enterprise-contract-service -l app.kubernetes.io/component=server
    # Uncomment the following if you want to wait for rekor
    # echo "Waiting for rekor server."
    # while ! curl --fail --insecure --output /dev/null --silent "https://rekor.$domain/api/v1/log"; do
    #     echo -n .
    #     sleep 3
    # done
fi
