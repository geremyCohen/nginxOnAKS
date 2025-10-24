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

get_service_ip() {
    arch=$1
    svc_name="nginx-${arch}-svc"
    kubectl -nnginx get svc $svc_name -o jsonpath="{.status.loadBalancer.ingress[*]['ip', 'hostname']}"
}

get_request() {
    svc_ip=$1
    curl -s http://$svc_ip/ | head -1
}

apply_nginx_config() {
    NAMESPACE="nginx"
    
    echo "Applying custom nginx.conf to all nginx pods..."
    
    # Create the custom nginx.conf content
    kubectl create configmap nginx-config --from-literal=nginx.conf='
user  nginx;

error_log  /var/log/nginx/error.log notice;
pid        /run/nginx.pid;

worker_processes auto;
events {
    worker_connections  1024;
}

http {

    server {
        listen 80;

        location / {
            root /usr/share/nginx/html;
        }
    }
        # cache informations about FDs, frequently accessed files
    # can boost performance, but you need to test those values
    open_file_cache max=200000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # access logs enabled for monitoring and debugging
    access_log /var/log/nginx/access.log;

    # copies data between one FD and other from within the kernel
    # faster than read() + write()
    sendfile on;

    # send headers in one piece, it is better than sending them one by one
    tcp_nopush on;

    # don'\''t buffer data sent, good for small data bursts in real time
    tcp_nodelay on;
    

    # allow the server to close connection on non responding client, this will free up memory
    reset_timedout_connection on;

    # request timed out -- default 60
    client_body_timeout 10;

    # if client stop responding, free up memory -- default 60
    send_timeout 2;

    # server will close connection after this time -- default 75
    keepalive_timeout 30;

    # number of requests client can make over keep-alive -- for testing environment
    keepalive_requests 100000;
}
' -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

    # Get all nginx deployments and update them
    for deployment in $(kubectl get deployments -n $NAMESPACE -o name | grep nginx); do
        deployment_name=$(echo $deployment | cut -d'/' -f2)
        echo "Updating $deployment_name..."
        
        # Add volume and volume mount to deployment
        kubectl patch deployment $deployment_name -n $NAMESPACE --type='json' -p='[
            {
                "op": "add",
                "path": "/spec/template/spec/volumes",
                "value": [{"name": "nginx-config", "configMap": {"name": "nginx-config"}}]
            },
            {
                "op": "add", 
                "path": "/spec/template/spec/containers/0/volumeMounts",
                "value": [{"name": "nginx-config", "mountPath": "/etc/nginx/nginx.conf", "subPath": "nginx.conf"}]
            }
        ]'
    done

    echo "Waiting for pods to restart with new configuration..."
    sleep 15

    # Install btop on all nginx pods
    echo "Installing btop on all nginx pods..."
    for pod in $(kubectl get pods -l app=nginx-multiarch -n $NAMESPACE -o name | sed 's/pod\///'); do
        echo "Installing btop on $pod..."
        kubectl exec -n $NAMESPACE $pod -- apt-get update -y >/dev/null 2>&1
        kubectl exec -n $NAMESPACE $pod -- apt-get install -y btop >/dev/null 2>&1
        echo "✓ btop installed on $pod"
    done

    echo "✅ Custom nginx.conf applied and btop installed on all pods!"
}

run_action() {
    action=$1
    arch=$2

    svc_ip=$(get_service_ip $arch)
    echo "Using service endpoint $svc_ip for $action on $(tput bold)$arch service$(tput sgr0)"

    case $action in
        get)
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
        *)
            echo "Invalid first argument. Use 'get'."
            exit 1
            ;;
    esac
}

case $1 in
    get)
        case $2 in
            intel|arm|amd|multiarch)
                run_action $1 $2
                ;;
            *)
                echo "Invalid second argument. Use 'intel', 'arm', 'amd', or 'multiarch'."
                exit 1
                ;;
        esac
        ;;
    put)
        case $2 in
            config)
                apply_nginx_config
                ;;
            *)
                echo "Invalid second argument. Use 'config'."
                exit 1
                ;;
        esac
        ;;
    login)
        case $2 in
            intel|arm|amd)
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
                echo "Invalid second argument. Use 'intel', 'arm', or 'amd'."
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Invalid first argument. Use 'get', 'put', or 'login'."
        exit 1
        ;;
esac

echo
