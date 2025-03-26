package proxmox_plugin

import (
	"context"
	"errors"
	"fmt"
	"log"

	"github.com/NX211/traefik-proxmox-provider/internal"
)

var ParserConfigLogLevelInfo string = "info"
var ParserConfigLogLevelDebug string = "debug"

type ParserConfig struct {
	ApiEndpoint string
	TokenId     string
	Token       string
	LogLevel    string
	ValidateSSL bool
}

func NewParserConfig(apiEndpoint, tokenID, token string) (ParserConfig, error) {
	if apiEndpoint == "" || tokenID == "" || token == "" {
		return ParserConfig{}, errors.New("missing mandatory values: apiEndpoint, tokenID or token")
	}
	return ParserConfig{
		ApiEndpoint: apiEndpoint,
		TokenId:     tokenID,
		Token:       token,
		LogLevel:    ParserConfigLogLevelInfo,
		ValidateSSL: true,
	}, nil
}

func NewClient(pc ParserConfig) *internal.ProxmoxClient {
	return internal.NewProxmoxClient(pc.ApiEndpoint, pc.TokenId, pc.Token, pc.ValidateSSL, pc.LogLevel)
}

func LogVersion(client *internal.ProxmoxClient, ctx context.Context) error {
	version, err := client.GetVersion(ctx)
	if err != nil {
		return err
	}
	log.Printf("PVE Version %s", version.Release)
	return nil
}

func GetServiceMap(client *internal.ProxmoxClient, ctx context.Context) (map[string][]internal.Service, error) {
	servicesMap := make(map[string][]internal.Service)

	nodes, err := client.GetNodes(ctx)
	if err != nil {
		log.Fatalf("error scanning nodes: %s", err)
	}

	for _, nodeStatus := range nodes {
		services, err := scanServices(client, ctx, nodeStatus.Node)
		if err != nil {
			log.Fatalf("error scanning services on node %s: %s", nodeStatus.Node, err)
		}
		servicesMap[nodeStatus.Node] = services
	}
	return servicesMap, nil
}

func getIPsOfService(client *internal.ProxmoxClient, ctx context.Context, nodeName string, vmID uint64) (ips []internal.IP, err error) {
	interfaces, err := client.GetVMNetworkInterfaces(ctx, nodeName, vmID)
	if err != nil {
		return nil, err
	}
	return interfaces.GetIPs(), nil
}

func scanServices(client *internal.ProxmoxClient, ctx context.Context, nodeName string) (services []internal.Service, err error) {
	// Scan virtual machines
	vms, err := client.GetVirtualMachines(ctx, nodeName)
	if err != nil {
		return nil, fmt.Errorf("error scanning VMs on node %s: %s", nodeName, err)
	}

	for _, vm := range vms {
		log.Printf("scanning vm %s/%s (%d): %s", nodeName, vm.Name, vm.VMID, vm.Status)
		
		if vm.Status == "running" {
			config, err := client.GetVMConfig(ctx, nodeName, vm.VMID)
			if err != nil {
				log.Printf("error getting VM config for %d: %s", vm.VMID, err)
				continue
			}
			
			service := internal.NewService(vm.VMID, vm.Name, config.GetTraefikMap())
			
			ips, err := getIPsOfService(client, ctx, nodeName, vm.VMID)
			if err == nil {
				service.IPs = ips
			}
			
			services = append(services, service)
		}
	}

	// Scan containers
	cts, err := client.GetContainers(ctx, nodeName)
	if err != nil {
		return nil, fmt.Errorf("error scanning containers on node %s: %s", nodeName, err)
	}

	for _, ct := range cts {
		log.Printf("scanning ct %s/%s (%d): %s", nodeName, ct.Name, ct.VMID, ct.Status)
		
		if ct.Status == "running" {
			config, err := client.GetContainerConfig(ctx, nodeName, ct.VMID)
			if err != nil {
				log.Printf("error getting container config for %d: %s", ct.VMID, err)
				continue
			}
			
			service := internal.NewService(ct.VMID, ct.Name, config.GetTraefikMap())
			services = append(services, service)
		}
	}

	return services, nil
}

func GetParserConfigLogLevel(logLevel string) string {
	if logLevel == "debug" {
		return internal.LogLevelDebug
	}
	return internal.LogLevelInfo
}
