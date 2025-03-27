# Traefik Proxmox Provider

![Traefik Proxmox Provider](https://raw.githubusercontent.com/nx211/traefik-proxmox-provider/main/.assets/logo.png)

A Traefik provider that automatically configures routing based on Proxmox VE virtual machines and containers.

## Features

- Automatically discovers Proxmox VE virtual machines and containers
- Configures routing based on VM/container metadata
- Supports both HTTP and HTTPS endpoints
- Configurable polling interval
- SSL validation options
- Logging configuration

## Installation

1. Add the plugin to your Traefik configuration:

```yaml
experimental:
  plugins:
    traefik-proxmox-provider:
      moduleName: github.com/NX211/traefik-proxmox-provider
      version: v0.4.0
```

2. Configure the provider in your dynamic configuration:

```yaml
# Dynamic configuration
providers:
  plugin:
    traefik-proxmox-provider:
      pollInterval: "5s"
      apiEndpoint: "https://proxmox.example.com"
      apiTokenId: "root@pam!traefik"
      apiToken: "your-api-token"
      apiLogging: "info"
      apiValidateSSL: "true"
```

## Configuration

### Provider Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pollInterval` | `string` | `"5s"` | How often to poll the Proxmox API for changes |
| `apiEndpoint` | `string` | - | The URL of your Proxmox VE API |
| `apiTokenId` | `string` | - | The API token ID (e.g., "root@pam!traefik") |
| `apiToken` | `string` | - | The API token secret |
| `apiLogging` | `string` | `"info"` | Log level for API operations ("debug" or "info") |
| `apiValidateSSL` | `string` | `"true"` | Whether to validate SSL certificates |

## Usage

1. Create an API token in Proxmox VE:
   - Go to Datacenter -> Permissions -> API Tokens
   - Add a new token with appropriate permissions
   - Copy the token ID and secret

2. Configure the provider in your Traefik configuration:
   - Set the `apiEndpoint` to your Proxmox VE server URL
   - Set the `apiTokenId` and `apiToken` from step 1
   - Adjust other options as needed

3. Add metadata to your VMs/containers:
   - In the VM/container description, add Traefik labels
   - Example: `traefik.enable=true`
   - Example: `traefik.http.routers.myapp.rule=Host(`myapp.example.com`)`

4. Restart Traefik to load the new configuration

## Examples

### Basic Configuration

```yaml
providers:
  plugin:
    traefik-proxmox-provider:
      pollInterval: "5s"
      apiEndpoint: "https://proxmox.example.com"
      apiTokenId: "root@pam!traefik"
      apiToken: "your-api-token"
      apiLogging: "info"
      apiValidateSSL: "true"
```

### VM/Container Metadata Example

Add this to your VM/container description in Proxmox:

```
traefik.enable=true
traefik.http.routers.myapp.rule=Host(`myapp.example.com`)
traefik.http.services.myapp.loadbalancer.server.port=8080
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
