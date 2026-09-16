// Package honeybee reaches cm-honeybee for the access details behind a
// honeybee ConnectionRef. Unlike cm-beetle, cm-honeybee returns credentials
// RSA-encrypted, so this package decrypts them (RSA-OAEP/SHA-512) with the
// key pkg/rsautil manages before handing back a HoneybeeConnConfig.
package honeybee

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	commonmodel "github.com/cloud-barista/cm-centipede/dmdl/common-model"
	"github.com/cloud-barista/cm-centipede/pkg/config"
	"github.com/cloud-barista/cm-centipede/pkg/rsautil"
	"github.com/rs/zerolog/log"
)

// ConnType constants used in HoneybeeConnConfig.ConnType.
const (
	ConnTypeSSH           = "ssh"
	ConnTypeObjectStorage = "objectStorage"
	ConnTypeDBMS          = "dbms"
)

// HoneybeeConnConfig is the normalised connection config derived from a
// honeybee ConnectionInfo response. Only the fields relevant to ConnType are
// populated; callers should switch on ConnType before reading credentials.
type HoneybeeConnConfig struct {
	ConnType string // "ssh" | "objectStorage" | "dbms"

	// SSH (ConnType = "ssh")
	Host       string
	Port       int
	User       string
	Password   string
	PrivateKey string

	// ObjectStorage (ConnType = "objectStorage")
	Endpoint  string
	AccessKey string
	SecretKey string
	UseSSL    bool

	// ProviderName and Region come from the connection's SOURCE GROUP rather than
	// from the connection itself, and they are read for one reason: cm-honeybee
	// keeps its provider knowledge to itself. It works out the endpoint, the
	// signing region, the TLS setting and the bucket addressing style on every
	// inspect and hands none of them back — os_endpoint stays whatever the caller
	// typed, and there is no field for the other three at all. So the only way to
	// reach a bucket the way honeybee reaches it is to fetch these two and run the
	// same table here.
	//
	// Region is the group's region_name, the one region a caller states. Whether
	// it also signs the request is the provider table's decision, not this
	// struct's — see ResolveS3Endpoint.
	ProviderName string
	Region       string

	// DBMS (ConnType = "dbms")
	DBType     string
	DBHost     string
	DBPort     int
	DBUsername string
	DBPassword string
	Database   string

	// Transport security for the DBMS connection, passed straight through to
	// transxex.DirectConfig. Read only on the direct path: an SSH-tunnelled
	// connection has no TLS settings, so these are ignored there.
	DBTLSMode  string
	DBTLSCAPEM string

	// SSH tunnel for DBMS (non-empty when db_access_type = "ssh-tunnel")
	SSHTunnelHost       string
	SSHTunnelPort       int
	SSHTunnelUser       string
	SSHTunnelPassword   string
	SSHTunnelPrivateKey string
}

// honeybeeConnectionInfo mirrors the JSON returned by
// GET /honeybee/connection_info/{connId}.
// Sensitive fields are RSA-OAEP/SHA-512 + base64-encoded in the response.
type honeybeeConnectionInfo struct {
	// SSH fields
	IPAddress  string `json:"ip_address,omitempty"`
	SSHPort    string `json:"ssh_port,omitempty"`
	User       string `json:"user,omitempty"`
	Password   string `json:"password,omitempty"`
	PrivateKey string `json:"private_key,omitempty"`

	// CSP fields
	ResourceType string `json:"resource_type,omitempty"`
	ResourceID   string `json:"resource_id,omitempty"`

	// DB fields
	DBType           string `json:"db_type,omitempty"`
	DBAccessType     string `json:"db_access_type,omitempty"` // "direct" | "ssh-tunnel"
	DBName           string `json:"db_name,omitempty"`
	DBHost           string `json:"db_host,omitempty"`
	DBPort           string `json:"db_port,omitempty"`
	DBUsername       string `json:"db_username,omitempty"`
	DBPassword       string `json:"db_password,omitempty"`
	DBConnectTimeout int    `json:"db_connect_timeout,omitempty"`
	DBTLSMode        string `json:"db_tls_mode,omitempty"`
	DBTLSCAPEM       string `json:"db_tls_ca_pem,omitempty"`

	// SourceGroupID is the bridge to the provider: the connection knows which
	// group it belongs to, and the group is where provider_name and region_name
	// live.
	SourceGroupID string `json:"source_group_id,omitempty"`

	// MinIO / ObjectStorage fields
	OSEndpoint        string `json:"os_endpoint,omitempty"`
	OSAccessKeyId     string `json:"os_access_key_id,omitempty"`
	OSSecretAccessKey string `json:"os_secret_access_key,omitempty"`
	OSUseSSL          bool   `json:"os_use_ssl,omitempty"`
}

// honeybeeSourceGroup is the part of GET /honeybee/source_group/{sgId} this
// package reads: the two fields that decide how an object storage bucket is
// addressed.
type honeybeeSourceGroup struct {
	ProviderName string `json:"provider_name,omitempty"`
	RegionName   string `json:"region_name,omitempty"`
}

// getJSON performs a GET against honeybee and decodes the body into out.
func getJSON(url string, out any) error {
	log.Debug().Str("url", url).Msg("calling honeybee API")

	resp, err := http.Get(url) //nolint:noctx
	if err != nil {
		return fmt.Errorf("honeybee unreachable: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read honeybee response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("honeybee returned %d: %s", resp.StatusCode, string(body))
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("parse honeybee response: %w", err)
	}
	return nil
}

// GetConnectionInfo calls the honeybee connection_info API for the given ref,
// decrypts RSA-OAEP/SHA-512 encrypted fields, and returns a HoneybeeConnConfig.
//
// An object storage connection costs a second call, for the source group that
// holds its provider. See the ProviderName field: honeybee resolves a bucket's
// address from the provider and hands none of that back, so the provider is
// fetched and the same table is run on this side.
//
// Errors:
//   - honeybee unreachable or non-200 response → wrapped error (caller returns 500)
//   - RSA decryption failure                   → wrapped error (caller returns 500)
func GetConnectionInfo(ref commonmodel.HoneybeeRef) (*HoneybeeConnConfig, error) {
	endpoint := strings.TrimRight(config.Conf.Honeybee.Endpoint, "/")

	var raw honeybeeConnectionInfo
	if err := getJSON(fmt.Sprintf("%s/honeybee/connection_info/%s", endpoint, ref.ConnectionID), &raw); err != nil {
		return nil, err
	}

	cfg, err := mapToConfig(&raw)
	if err != nil {
		return nil, err
	}
	if cfg.ConnType != ConnTypeObjectStorage {
		return cfg, nil
	}

	// Always required, even when the connection states an endpoint of its own:
	// the provider still decides the bucket addressing style, and a Tencent
	// bucket reached with the wrong one fails after the endpoint resolved fine.
	if raw.SourceGroupID == "" {
		return nil, fmt.Errorf("object storage connection %s names no source group, so its provider cannot be resolved", ref.ConnectionID)
	}
	var sg honeybeeSourceGroup
	if err := getJSON(fmt.Sprintf("%s/honeybee/source_group/%s", endpoint, raw.SourceGroupID), &sg); err != nil {
		return nil, fmt.Errorf("get source group %s of object storage connection %s: %w", raw.SourceGroupID, ref.ConnectionID, err)
	}
	cfg.ProviderName = sg.ProviderName
	cfg.Region = sg.RegionName
	return cfg, nil
}

// mapToConfig converts a raw honeybee response to HoneybeeConnConfig,
// decrypting sensitive fields along the way.
func mapToConfig(raw *honeybeeConnectionInfo) (*HoneybeeConnConfig, error) {
	cfg := &HoneybeeConnConfig{}

	switch {
	case raw.ResourceType != "":
		// CSP type — resource_type discriminates the sub-kind.
		if raw.ResourceType == "object_storage" {
			if err := fillObjectStorage(cfg, raw); err != nil {
				return nil, err
			}
		} else {
			// "vm" | "k8s" — SSH credentials are stored in the SSH fields.
			if err := fillSSH(cfg, raw); err != nil {
				return nil, err
			}
		}

	case raw.OSEndpoint != "", raw.OSAccessKeyId != "":
		// MinIO / S3-compatible (SourceGroup.Type = "minio").
		// Checked before ip_address because SSH-tunnel MinIO connections carry
		// both ip_address (tunnel host) and os_endpoint; os_endpoint wins.
		//
		// os_access_key_id is the second marker because os_endpoint is OPTIONAL
		// for every provider whose host honeybee builds itself — aws, ncp and the
		// rest of its provider table only need a region. Keying on the endpoint
		// alone recognised nothing but the onprem and openstack shapes, where the
		// caller supplies the host, and answered everything else with "cannot
		// determine connection type".
		if err := fillObjectStorage(cfg, raw); err != nil {
			return nil, err
		}

	case raw.DBType != "":
		// Direct DBMS or SSH-tunnel DBMS (SourceGroup.Type = "db").
		// Checked before ip_address for the same reason as OSEndpoint above.
		if err := fillDBMS(cfg, raw); err != nil {
			return nil, err
		}

	case raw.IPAddress != "":
		// Pure SSH connection (SourceGroup.Type = "ssh")
		if err := fillSSH(cfg, raw); err != nil {
			return nil, err
		}

	default:
		return nil, fmt.Errorf("cannot determine connection type from honeybee response")
	}

	return cfg, nil
}

// fillSSH populates SSH-type fields, decrypting user/password/private_key.
func fillSSH(cfg *HoneybeeConnConfig, raw *honeybeeConnectionInfo) error {
	cfg.ConnType = ConnTypeSSH
	cfg.Host = raw.IPAddress

	port, _ := strconv.Atoi(raw.SSHPort)
	cfg.Port = port

	var err error
	if cfg.User, err = decryptField(raw.User); err != nil {
		return fmt.Errorf("decrypt ssh user: %w", err)
	}
	if cfg.Password, err = decryptField(raw.Password); err != nil {
		return fmt.Errorf("decrypt ssh password: %w", err)
	}
	pk, err := decryptField(raw.PrivateKey)
	if err != nil {
		return fmt.Errorf("decrypt ssh private_key: %w", err)
	}
	if pk == "-" {
		pk = ""
	}
	cfg.PrivateKey = pk
	return nil
}

// fillObjectStorage populates ObjectStorage-type fields, decrypting access/secret keys.
func fillObjectStorage(cfg *HoneybeeConnConfig, raw *honeybeeConnectionInfo) error {
	cfg.ConnType = ConnTypeObjectStorage
	cfg.Endpoint = raw.OSEndpoint
	cfg.UseSSL = raw.OSUseSSL
	// Region is not a connection field: it comes from the source group, and
	// GetConnectionConfig fills it in after this.

	var err error
	if cfg.AccessKey, err = decryptField(raw.OSAccessKeyId); err != nil {
		return fmt.Errorf("decrypt os_access_key_id: %w", err)
	}
	if cfg.SecretKey, err = decryptField(raw.OSSecretAccessKey); err != nil {
		return fmt.Errorf("decrypt os_secret_access_key: %w", err)
	}
	return nil
}

// fillDBMS populates DBMS-type fields, decrypting db_username and db_password.
// When db_access_type = "ssh-tunnel", SSH tunnel credentials are also populated.
func fillDBMS(cfg *HoneybeeConnConfig, raw *honeybeeConnectionInfo) error {
	cfg.ConnType = ConnTypeDBMS
	cfg.DBType = raw.DBType
	cfg.DBHost = raw.DBHost
	cfg.Database = raw.DBName
	// Not decrypted: honeybee RSA-wraps credentials, and a CA certificate is a
	// public value.
	cfg.DBTLSMode = raw.DBTLSMode
	cfg.DBTLSCAPEM = raw.DBTLSCAPEM

	port, _ := strconv.Atoi(raw.DBPort)
	cfg.DBPort = port

	var err error
	if cfg.DBUsername, err = decryptField(raw.DBUsername); err != nil {
		return fmt.Errorf("decrypt db_username: %w", err)
	}
	if cfg.DBPassword, err = decryptField(raw.DBPassword); err != nil {
		return fmt.Errorf("decrypt db_password: %w", err)
	}

	// SSH tunnel credentials for ssh-tunnel access type
	if raw.DBAccessType == "ssh-tunnel" && raw.IPAddress != "" {
		cfg.SSHTunnelHost = raw.IPAddress
		tunnelPort, _ := strconv.Atoi(raw.SSHPort)
		cfg.SSHTunnelPort = tunnelPort

		if cfg.SSHTunnelUser, err = decryptField(raw.User); err != nil {
			return fmt.Errorf("decrypt ssh tunnel user: %w", err)
		}
		if cfg.SSHTunnelPassword, err = decryptField(raw.Password); err != nil {
			return fmt.Errorf("decrypt ssh tunnel password: %w", err)
		}
		pk, err := decryptField(raw.PrivateKey)
		if err != nil {
			return fmt.Errorf("decrypt ssh tunnel private_key: %w", err)
		}
		if pk == "-" {
			pk = ""
		}
		cfg.SSHTunnelPrivateKey = pk
	}

	return nil
}

// decryptField base64-decodes then RSA-OAEP/SHA-512 decrypts a single
// honeybee-encrypted field. Empty input is returned as-is.
func decryptField(encrypted string) (string, error) {
	if encrypted == "" {
		return "", nil
	}
	raw, err := base64.StdEncoding.DecodeString(encrypted)
	if err != nil {
		return "", fmt.Errorf("base64 decode: %w", err)
	}
	plain, err := rsautil.DecryptWithPrivateKey(raw, rsautil.PrivKey)
	if err != nil {
		return "", fmt.Errorf("rsa decrypt: %w", err)
	}
	return string(plain), nil
}
