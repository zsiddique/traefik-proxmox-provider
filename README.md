# Traefik Proxmox Provider

![Traefik Proxmox Provider](https://raw.githubusercontent.com/nx211/traefik-proxmox-provider/main/.assets/logo.png)

A [Traefik](https://traefik.io/) provider plugin that automatically configures routing based on Proxmox VE virtual machines and containers.

## Features

* Automatic discovery of Proxmox VE virtual machines and containers
* Traefik configuration extraction from VM/CT description fields
* Automatic IP address discovery via QEMU Guest Agent
* Manual IP configuration for containers
* Configurable polling interval for real-time updates
* SSL validation options
* Configurable logging levels
* Support for both VMs (QEMU) and Containers (LXC)

## Installation

To configure the Proxmox Provider in your Traefik instance:

1. Enable the plugin in your static configuration:

```yaml
# Static configuration
experimental:
  plugins:
    proxmox:
      moduleName: github.com/NX211/traefik-proxmox-provider
      version: v0.1.0
```

2. Configure the provider in your dynamic configuration:

```yaml
# Dynamic configuration
providers:
  plugin:
    proxmox:
      pollInterval: "5s"
      apiEndpoint: "https://proxmox.example.com"
      apiTokenId: "root@pam!traefik"
      apiToken: "your-api-token"
      apiLogging: "info"
      apiValidateSSL: "true"
```

## Configuration

### Provider Configuration Options

| Option | Type | Required | Default | Description |
|--------|------|----------|---------|-------------|
| pollInterval | string | No | "5s" | How often to poll the Proxmox API |
| apiEndpoint | string | Yes | | The URL of your Proxmox API endpoint |
| apiTokenId | string | Yes | | The Proxmox API token ID |
| apiToken | string | Yes | | The Proxmox API token |
| apiLogging | string | No | "info" | Logging level ("info" or "debug") |
| apiValidateSSL | string | No | "true" | Whether to validate SSL certificates |

### VM/CT Configuration Format

Each service's Traefik configuration must be specified in the VM/CT description field using this format:

```ini
"traefik.enable": "true" 
"traefik.http.routers.myapp.entrypoints": "http" 
"traefik.http.routers.myapp.rule": "Host(`example.com`)" 
"traefik.http.services.myapp.loadbalancer.server.port": "80"
```

For containers that need manual IP configuration:

```ini
"traefik.enable": "true"
"traefik.http.routers.web.entrypoints": "http"
"traefik.http.routers.web.rule": "Host(`web.example.com`)"
"traefik.http.services.web.loadbalancer.server.port": "80"
"traefik.http.services.web.loadbalancer.server.ipv4": "192.168.168.131" 
```

## Required Permissions

The plugin requires these Proxmox API permissions:

```
token:root@pam!traefik:0:0::
role:API-READER:Datastore.Audit,SDN.Audit,Sys.Audit,VM.Audit,VM.Config.Options:
acl:1:/:root@pam!traefik:API-READER:
```

## Example Usage

### Basic Configuration

```yaml
providers:
  plugin:
    proxmox:
      pollInterval: "5s"
      apiEndpoint: "https://proxmox.example.com"
      apiTokenId: "root@pam!traefik"
      apiToken: "your-api-token"
      apiLogging: "debug"
      apiValidateSSL: "false"
```

### VM Configuration Example

In your Proxmox VM's description field:

```ini
"traefik.enable": "true" 
"traefik.http.routers.myvm.entrypoints": "http" 
"traefik.http.routers.myvm.rule": "Host(`myvm.example.com`)" 
"traefik.http.services.myvm.loadbalancer.server.port": "80"
```

## Development

To build and test the plugin:

```bash
# Run tests
go test ./...

# Build the plugin
go build ./...
```

### Local Development

For local development, you can use environment variables with direnv:

```bash
# Copy the example .envrc file
cp .envrc.example .envrc

# Edit the file with your configuration
# Then allow it to load
direnv allow
```

forked from phaus/traefik-proxmox-plugin

## License

This project is licensed under the Apache License 2.0. See the LICENSE file for details.
