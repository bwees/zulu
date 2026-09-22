// Package secret wraps the Zulip API keys the service stores.
//
// The key-encryption key comes from the environment and is never written to the
// database, so a stolen database file alone does not yield working credentials.
// See SECURITY.md for what this does and does not protect against.
package secret

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
)

var ErrCiphertextTooShort = errors.New("secret: ciphertext is shorter than the nonce")

// Sealer encrypts with AES-256-GCM. Each box is nonce || ciphertext.
type Sealer struct {
	aead cipher.AEAD
}

func NewSealer(key []byte) (*Sealer, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("secret: new cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("secret: new gcm: %w", err)
	}
	return &Sealer{aead: aead}, nil
}

// Seal encrypts plaintext. The additional data is authenticated but not
// encrypted; binding a box to the row it belongs to stops a database-level
// attacker from moving one user's credential onto another user's row.
func (s *Sealer) Seal(plaintext, additionalData []byte) ([]byte, error) {
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("secret: read nonce: %w", err)
	}
	return s.aead.Seal(nonce, nonce, plaintext, additionalData), nil
}

func (s *Sealer) Open(box, additionalData []byte) ([]byte, error) {
	nonceSize := s.aead.NonceSize()
	if len(box) < nonceSize {
		return nil, ErrCiphertextTooShort
	}
	plaintext, err := s.aead.Open(nil, box[:nonceSize], box[nonceSize:], additionalData)
	if err != nil {
		return nil, fmt.Errorf("secret: open: %w", err)
	}
	return plaintext, nil
}
