#!/usr/bin/env bash

# Utility functions for deployment scripts

# Convert runtime container env variables
# e.g: "CUDA_VISIBLE_DEVICES='', VLLM_NO_USAGE_STATS=1, HUGGING_FACE_HUB_TOKEN=secret:hf-token-secret:token"
# for secret following format: "secret:<name>:<key>"
#   - name: k8s secret's name
#   - key: key within the secret
convert_env_to_yaml() {
    local env_string="${1}"
    local namespace="${2}"
    local yaml_env=""
    IFS=',' read -ra env_pairs <<< "${env_string}"
    for pair in "${env_pairs[@]}"; do
        IFS='=' read -r key value <<< "${pair}"
        # Strip outer quotes from value
        value=$(echo "${value}" | sed 's/^["'\'']*//;s/["'\'']*$//')

        # check if value is a secret reference which vllm requires to download model from Huggingface.
        # format: "secret:name:key" (e.g: "secret:hf-token-secret:token")
        if [[ "${value}" =~ ^secret:([^:]+):([^:]+)$ ]]; then
            local secret_name="${BASH_REMATCH[1]}"
            local secret_key="${BASH_REMATCH[2]}"

            # check if the secret exists
            if ! kubectl get secret "${secret_name}" -n "${namespace}" &>/dev/null; then
                echo "Error: Secret '${secret_name}' not found in namespace '${namespace}'. Please create it before running script again"
                exit 1
            fi
            if [ -n "${yaml_env}" ]; then
                yaml_env="${yaml_env}\n"
            fi
            yaml_env="${yaml_env}            - name: ${key}\n              valueFrom:\n                secretKeyRef:\n                  name: ${secret_name}\n                  key: ${secret_key}"
        else
            if [ -n "${yaml_env}" ]; then
                yaml_env="${yaml_env}\n"
            fi
            yaml_env="${yaml_env}            - name: ${key}\n              value: \"${value}\""
        fi
    done
    echo -e "${yaml_env}"
}

# Detect the architecture of the cluster nodes (falls back to the local machine).
# Can be overridden with TARGET_ARCH (e.g. TARGET_ARCH=s390x). The result is
# exported so later calls (including subshells) do not query the cluster again.
detect_target_arch() {
    if [ -z "${TARGET_ARCH:-}" ]; then
        local node_archs
        node_archs="$(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}' 2>/dev/null | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ *$//' || true)"
        if [ -z "${node_archs}" ]; then
            node_archs="$(uname -m 2>/dev/null || true)"
        fi
        export TARGET_ARCH="${node_archs}"
    fi
}

# True only when every cluster node is s390x, so mixed clusters keep the defaults.
is_s390x_platform() {
    detect_target_arch
    [ "${TARGET_ARCH}" = "s390x" ]
}

# can extend later once we support other providers
validate_provider() {
    local provider="${1}"
    case "${provider}" in
        "ollama"|"vllm")
            # Only vLLM is supported on s390x: the ollama image has no s390x build.
            if [ "${provider}" = "ollama" ] && is_s390x_platform; then
                echo "Error: provider 'ollama' is not supported on s390x (no s390x image)."
                echo "Use: --provider vllm"
                return 1
            fi
            return 0
            ;;
        *)
            echo "Error: Unsupported provider '${provider}'"
            echo "Supported providers: ollama, vllm for now"
            return 1
            ;;
    esac
}

# Set default values for supported provider
get_provider_config() {
    local provider="${1}"
    case "${provider}" in
        "ollama")
            echo "IMAGE=docker.io/ollama/ollama:latest"
            echo "INFERENCE_SERVER=ollama"
            echo "COMMAND=[\"/bin/sh\", \"-c\"]"
            echo "DEFAULT_MODEL=llama3.2:1b"
            echo "PORT=11434"
            echo "HEALTH_PATH=/api/version"
            echo "DEFAULT_ENV_VARS=OLLAMA_KEEP_ALIVE=60m"
            ;;
        "vllm")
            if is_s390x_platform; then
                # docker.io/vllm/vllm-openai has no s390x build; use the RHOAI vLLM CPU image
                # and a small default model that fits CPU-only s390x nodes.
                echo "IMAGE=registry.redhat.io/rhoai/odh-vllm-cpu-rhel9:v3.0.0"
                echo "DEFAULT_MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0"
            else
                echo "IMAGE=docker.io/vllm/vllm-openai:latest"
                echo "DEFAULT_MODEL=meta-llama/Llama-3.2-1B"
            fi
            echo "INFERENCE_SERVER=vllm"
            echo "COMMAND=[\"/bin/sh\", \"-c\"]"
            echo "PORT=8000"
            echo "HEALTH_PATH=/health"
            echo "DEFAULT_ENV_VARS=CUDA_VISIBLE_DEVICES='', VLLM_NO_USAGE_STATS=1, VLLM_TARGET_DEVICE=cpu, VLLM_ENFORCE_EAGER=1, HUGGING_FACE_HUB_TOKEN=secret:hf-token-secret:token"
            ;;
    esac
}

# Generate namespace name
get_namespace() {
    local provider="${1}"
    echo "${provider}-dist"
}

# Generate deployment name
get_server_name() {
    local provider="${1}"
    echo "${provider}-server"
}

# Generate volume mount name
get_volume_name() {
    local provider="${1}"
    echo "${provider}-data"
}

# Generate security related YAML and SCC based on provider
generate_security_context() {
    local provider="${1}"
    local namespace="${2}"
    local service_account="${provider}-sa"

    # OpenShift requires specific permissions in order for the container to run as uid 0
    if [ "${provider}" = "ollama" ]; then
        # Create ServiceAccount for Ollama (needed for SCC)
        echo "Checking if ServiceAccount ${service_account} exists..."
        if ! kubectl get sa "${service_account}" -n "${namespace}" &> /dev/null; then
            echo "Creating ServiceAccount ${service_account}..."
            kubectl create sa "${service_account}" -n "${namespace}"
        else
            echo "ServiceAccount ${service_account} already exists"
        fi
        export SERVICE_ACCOUNT="${service_account}"

        # Generate security context YAML for Ollama (need root)
        SECURITY_CONTEXT_YAML="      securityContext:
        runAsUser: 0
        runAsGroup: 0
        fsGroup: 0"
        CONTAINER_SECURITY_CONTEXT_YAML="securityContext:
            allowPrivilegeEscalation: true
            runAsNonRoot: false"
        OPENSHIFT_ANNOTATION=""

        if kubectl api-resources --api-group=security.openshift.io | grep -iq 'SecurityContextConstraints'; then
            "$(dirname "${BASH_SOURCE[0]}")/quickstart-scc.sh" "${provider}"
        fi
    else
        # For vLLM, use restricted-v2 SCC annotation (do not create new SCC resource)
        SECURITY_CONTEXT_YAML=""
        CONTAINER_SECURITY_CONTEXT_YAML="securityContext:
            runAsNonRoot: false"

        # Add annotation for restricted-v2 SCC to deployment
        if kubectl api-resources --api-group=security.openshift.io | grep -iq 'SecurityContextConstraints'; then
            OPENSHIFT_ANNOTATION="      annotations:
        openshift.io/required-scc: restricted-v2"
        fi
    fi

    # Export variables so they can be used by deploy-quickstart.sh
    export SECURITY_CONTEXT_YAML
    export CONTAINER_SECURITY_CONTEXT_YAML
    export OPENSHIFT_ANNOTATION

}

# Load provider-specific configuration and set up environment
load_provider_config() {
    local provider="${1}"
    local model="${2}"
    local env_vars="${3}"

    # Validate provider
    if ! validate_provider "${provider}"; then
        exit 1
    fi

    # Detect once here so the exported TARGET_ARCH is visible to the subshell below
    detect_target_arch

    # Load provider configuration
    while IFS='=' read -r key value; do
        if [[ -n "${key}" && ! "${key}" =~ ^# ]]; then
            eval "${key}=\"${value}\""
        fi
    done < <(get_provider_config "${provider}")

    # Use provided model or default
    if [ -z "${model}" ]; then
        export MODEL="${DEFAULT_MODEL}"
    else
        export MODEL="${model}"
    fi

    # Set default args after MODEL is determined, 15s is to ensure model has been downloaded
    if [ "${provider}" = "ollama" ]; then
        export INIT_ARGS="ollama serve & sleep 15 && ollama pull ${MODEL}"
        export DEFAULT_ARGS="ollama serve"
    else
        if is_s390x_platform; then
            # The RHOAI vLLM CPU image takes the model as a positional argument. Cap the context
            # length at 2048 so it fits the default max_num_batched_tokens on CPU.
            export DEFAULT_ARGS="vllm serve ${MODEL} --dtype auto --max-model-len 2048"
        else
            export DEFAULT_ARGS="vllm serve --dtype auto --model ${MODEL}"
        fi
        export INIT_ARGS="sleep 1"  # here only to pull down the same image in initContainer
    fi

    # Use provided env vars or default ones
    if [ -z "${env_vars}" ]; then
        export ENV_VARS="${DEFAULT_ENV_VARS}"
    else
        export ENV_VARS="${env_vars}"
    fi
}
