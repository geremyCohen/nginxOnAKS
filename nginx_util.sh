#!/bin/bash

# Check for required dependencies
check_dependencies() {
    missing_deps=()
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}"
        echo ""
        for dep in "${missing_deps[@]}"; do
            case $dep in
                curl)
                    echo "Install curl:"
                    echo "  Ubuntu/Debian: sudo apt-get install curl"
                    echo "  RHEL/CentOS: sudo yum install curl"
                    echo "  macOS: brew install curl"
                    ;;
                jq)
                    echo "Install jq:"
                    echo "  Ubuntu/Debian: sudo apt-get install jq"
                    echo "  RHEL/CentOS: sudo yum install jq"
                    echo "  macOS: brew install jq"
                    ;;
            esac
            echo ""
        done
        exit 1
    fi
}

# Check dependencies before proceeding
check_dependencies

check_wrk_dependency() {
    if ! command -v wrk &> /dev/null; then
        echo "Error: wrk is not installed"
        echo ""
        echo "Install wrk:"
        echo "  Ubuntu/Debian: sudo apt-get install wrk"
        echo "  RHEL/CentOS: sudo yum install wrk"
        echo "  macOS: brew install wrk"
        echo ""
        echo "Or build from source: https://github.com/wg/wrk"
        exit 1
    fi
}

get_service_ip() {
    arch=$1
    svc_name="nginx-${arch}-svc"
    kubectl -nnginx get svc $svc_name -o jsonpath="{.status.loadBalancer.ingress[*]['ip', 'hostname']}"
}

get_request() {
    svc_ip=$1
    curl -s http://$svc_ip/ | head -1
}

install_btop() {
    NAMESPACE="nginx"
    
    echo "Installing btop on all nginx pods..."
    for pod in $(kubectl get pods -l app=nginx-multiarch -n $NAMESPACE -o name | sed 's/pod\///'); do
        echo "Installing btop on $pod..."
        kubectl exec -n $NAMESPACE $pod -- apt-get update -y >/dev/null 2>&1
        kubectl exec -n $NAMESPACE $pod -- apt-get install -y btop >/dev/null 2>&1
        echo "✓ btop installed on $pod"
    done

    echo "✅ btop installed on all pods!"
}

run_action() {
    action=$1
    arch=$2
    duration=${3:-30}
    connections=${4:-45}

    case $action in
        curl)
            svc_ip=$(get_service_ip $arch)
            echo "Using service endpoint $svc_ip for $action on $(tput bold)$arch service$(tput sgr0)"
            
            # Make the request
            response=$(get_request $svc_ip)
            echo "Response:"
            echo "$response" | jq .
            
            # Extract server name from JSON response
            serving_pod=$(echo "$response" | grep -o '"server":"[^"]*"' | cut -d'"' -f4)
            
            if [ -n "$serving_pod" ]; then
                # Extract architecture from pod name and bold it
                pod_arch=$(echo "$serving_pod" | sed 's/nginx-\([^-]*\)-.*/\1/')
                bold_pod=$(echo "$serving_pod" | sed "s/nginx-\([^-]*\)-/nginx-$(tput bold)\1$(tput sgr0)-/")
                echo "Served by: $bold_pod"
            else
                echo "Served by: Unable to determine"
            fi
            ;;
        wrk)
            check_wrk_dependency
            
            if [ "$arch" = "both" ]; then
                # Run wrk against both intel and arm in parallel
                intel_ip=$(get_service_ip intel)
                arm_ip=$(get_service_ip arm)
                
                intel_cmd="wrk -t1 -c${connections} -d${duration} http://$intel_ip/"
                arm_cmd="wrk -t1 -c${connections} -d${duration} http://$arm_ip/"
                
                echo "Running wrk against both architectures in parallel..."
                echo ""
                echo "$(tput bold)Intel:$(tput sgr0) $intel_cmd"
                echo "$(tput bold)ARM:$(tput sgr0) $arm_cmd"
                echo ""
                echo "========================================"
                
                # Create temp files for output
                intel_out=$(mktemp)
                arm_out=$(mktemp)
                
                # Run both in parallel and capture output to files
                $intel_cmd > "$intel_out" 2>&1 &
                intel_pid=$!
                
                $arm_cmd > "$arm_out" 2>&1 &
                arm_pid=$!
                
                # Wait for both to complete
                wait $intel_pid
                wait $arm_pid
                
                # Display results sequentially
                echo ""
                echo "$(tput bold)INTEL RESULTS:$(tput sgr0)"
                cat "$intel_out"
                
                echo ""
                echo "$(tput bold)ARM RESULTS:$(tput sgr0)"
                cat "$arm_out"
                
                # Cleanup temp files
                rm -f "$intel_out" "$arm_out"
                
                echo ""
                echo "========================================"
                echo "Both tests completed"
            else
                svc_ip=$(get_service_ip $arch)
                echo "Using service endpoint $svc_ip for $action on $(tput bold)$arch service$(tput sgr0)"
                
                wrk_cmd="wrk -t1 -c${connections} -d${duration} http://$svc_ip/"
                echo "Now running wrk commandline: $wrk_cmd"
                echo ""
                $wrk_cmd
            fi
            ;;
        *)
            echo "Invalid action. Use 'curl' or 'wrk'."
            exit 1
            ;;
    esac
}

case $1 in
    curl)
        case $2 in
            intel|arm|multiarch)
                run_action $1 $2
                ;;
            *)
                echo "Invalid second argument. Use 'intel', 'arm', or 'multiarch'."
                exit 1
                ;;
        esac
        ;;
    wrk)
        case $2 in
            intel|arm|multiarch|both)
                run_action $1 $2 $3 $4
                ;;
            *)
                echo "Invalid second argument. Use 'intel', 'arm', 'multiarch', or 'both'."
                exit 1
                ;;
        esac
        ;;
    put)
        case $2 in
            btop)
                install_btop
                ;;
            *)
                echo "Invalid second argument. Use 'btop'."
                exit 1
                ;;
        esac
        ;;
    login)
        case $2 in
            intel|arm)
                # Get the pod for the specified architecture
                pod_name=$(kubectl get pods -l arch=$2 -nnginx -o name | sed 's/pod\///')
                if [ -n "$pod_name" ]; then
                    echo "Connecting to $(tput bold)$2$(tput sgr0) pod: $pod_name"
                    kubectl exec -it -nnginx $pod_name -- /bin/bash
                else
                    echo "No $2 pod found"
                    exit 1
                fi
                ;;
            *)
                echo "Invalid second argument. Use 'intel' or 'arm'."
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Invalid first argument. Use 'curl', 'wrk', 'put', or 'login'."
        exit 1
        ;;
esac

echo
