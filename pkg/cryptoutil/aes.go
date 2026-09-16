package cryptoutil

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/cloud-barista/cm-centipede/pkg/config"
	"github.com/rs/zerolog/log"
)

const encPrefix = "enc:"

// AESKey is the global AES-256 key set by InitKey at startup.
var AESKey []byte

// Encrypt encrypts plaintext with AES-256-GCM and returns "enc:<base64(nonce+ciphertext)>".
// nonce is 12 random bytes prepended to the ciphertext before base64 encoding.
func Encrypt(plaintext string, key []byte) (string, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", fmt.Errorf("create cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("create GCM: %w", err)
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", fmt.Errorf("generate nonce: %w", err)
	}

	// Seal appends ciphertext+tag to nonce, producing nonce||ciphertext||tag.
	blob := gcm.Seal(nonce, nonce, []byte(plaintext), nil)
	return encPrefix + base64.StdEncoding.EncodeToString(blob), nil
}

// Decrypt decrypts a value produced by Encrypt.
// If the value does not start with "enc:" it is returned unchanged (passthrough).
func Decrypt(encrypted string, key []byte) (string, error) {
	if !strings.HasPrefix(encrypted, encPrefix) {
		return encrypted, nil
	}

	blob, err := base64.StdEncoding.DecodeString(encrypted[len(encPrefix):])
	if err != nil {
		return "", fmt.Errorf("decode base64: %w", err)
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return "", fmt.Errorf("create cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("create GCM: %w", err)
	}

	ns := gcm.NonceSize()
	if len(blob) < ns {
		return "", fmt.Errorf("ciphertext too short")
	}
	plaintext, err := gcm.Open(nil, blob[:ns], blob[ns:], nil)
	if err != nil {
		return "", fmt.Errorf("decrypt: %w", err)
	}
	return string(plaintext), nil
}

// InitKey loads the AES-256 key from config.Conf.Encryption.SecretKey (base64).
// If the key is unset a fresh 32-byte key is generated, base64-encoded, written
// back to cm-centipede.yaml, and returned.
func InitKey() []byte {
	encoded := config.Conf.Encryption.SecretKey

	if encoded == "" {
		raw := make([]byte, 32)
		if _, err := io.ReadFull(rand.Reader, raw); err != nil {
			panic("generate AES key: " + err.Error())
		}
		encoded = base64.StdEncoding.EncodeToString(raw)
		config.Conf.Encryption.SecretKey = encoded
		persistSecretKey(encoded)
		log.Info().Msg("AES-256 key generated and saved to config")
		AESKey = raw
		return raw
	}

	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(raw) != 32 {
		// Treat the raw string as the key (pad/truncate to 32 bytes).
		raw = make([]byte, 32)
		copy(raw, []byte(encoded))
		log.Warn().Msg("encryption.secretKey is not valid base64-32; using raw bytes")
	}
	AESKey = raw
	return raw
}

// persistSecretKey writes the generated key back into the YAML config file.
func persistSecretKey(encoded string) {
	candidates := []string{
		"./conf/cm-centipede.yaml",
		filepath.Join(config.RootPath(), "conf", "cm-centipede.yaml"),
	}
	for _, p := range candidates {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		updated := strings.Replace(string(data), `secretKey: ""`, `secretKey: `+encoded, 1)
		if updated == string(data) {
			updated = strings.Replace(string(data), "secretKey: ''", "secretKey: "+encoded, 1)
		}
		if err := os.WriteFile(p, []byte(updated), 0600); err != nil {
			log.Warn().Err(err).Str("path", p).Msg("failed to persist AES key to config")
		}
		return
	}
	log.Warn().Msg("config file not found; AES key not persisted")
}
