// Package config reads and writes ~/.config/chit/config.json, shared by the
// CLI and chitd.
package config

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/slastra/chit/internal/protocol"
)

// Config is ~/.config/chit/config.json. It holds a session token, so it is
// written mode 600.
type Config struct {
	Server string          `json:"server"`
	Token  string          `json:"token,omitempty"`
	Device string          `json:"device"`
	User   protocol.Person `json:"user"`

	// ActivityToasts turns chitd's toasts for other people's edits on shared
	// notes on or off. Missing means on.
	ActivityToasts *bool `json:"activity_toasts,omitempty"`
}

// Toasts reports whether activity toasts are on.
func (c *Config) Toasts() bool { return c.ActivityToasts == nil || *c.ActivityToasts }

func Path() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "chit", "config.json"), nil
}

// Load reads the config, filling in a device id the first time.
func Load() (*Config, error) {
	p, err := Path()
	if err != nil {
		return nil, err
	}
	c := &Config{}
	b, err := os.ReadFile(p)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	if err == nil {
		if err := json.Unmarshal(b, c); err != nil {
			return nil, err
		}
	}
	if c.Device == "" {
		c.Device = RandomString(8)
	}
	if env := os.Getenv("CHIT_SERVER"); env != "" {
		c.Server = env
	}
	return c, nil
}

// Save writes the config atomically, mode 600.
func (c *Config) Save() error {
	p, err := Path()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

const idAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789"

// RandomString draws n characters from [a-z0-9] without modulo bias.
func RandomString(n int) string {
	out := make([]byte, 0, n)
	buf := make([]byte, n*2)
	for len(out) < n {
		rand.Read(buf)
		for _, b := range buf {
			if int(b) < 252 { // 252 = 7 * 36
				out = append(out, idAlphabet[int(b)%36])
				if len(out) == n {
					break
				}
			}
		}
	}
	return string(out)
}

// NewID makes a record id in PocketBase's format.
func NewID() string { return RandomString(15) }
