package secret_test

import (
	"bytes"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/bwees/zulu/service/internal/secret"
)

func testKey() []byte { return bytes.Repeat([]byte{7}, 32) }

func TestSealRoundTrip(t *testing.T) {
	sealer, err := secret.NewSealer(testKey())
	require.NoError(t, err)

	box, err := sealer.Seal([]byte("api-key"), []byte("realm|1"))
	require.NoError(t, err)

	plaintext, err := sealer.Open(box, []byte("realm|1"))
	require.NoError(t, err)
	assert.Equal(t, "api-key", string(plaintext))
	assert.NotContains(t, string(box), "api-key")
}

func TestSealUsesAFreshNonce(t *testing.T) {
	sealer, err := secret.NewSealer(testKey())
	require.NoError(t, err)

	first, err := sealer.Seal([]byte("api-key"), nil)
	require.NoError(t, err)
	second, err := sealer.Seal([]byte("api-key"), nil)
	require.NoError(t, err)

	assert.NotEqual(t, first, second, "the same plaintext must not encrypt to the same bytes")
}

func TestOpenRejectsTampering(t *testing.T) {
	sealer, err := secret.NewSealer(testKey())
	require.NoError(t, err)
	box, err := sealer.Seal([]byte("api-key"), []byte("realm|1"))
	require.NoError(t, err)

	tests := []struct {
		name  string
		box   []byte
		extra []byte
	}{
		{name: "wrong binding", box: box, extra: []byte("realm|2")},
		{name: "flipped byte", box: flip(box), extra: []byte("realm|1")},
		{name: "truncated", box: box[:4], extra: []byte("realm|1")},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := sealer.Open(test.box, test.extra)

			assert.Error(t, err)
		})
	}
}

func TestOpenWithAnotherKeyFails(t *testing.T) {
	sealer, err := secret.NewSealer(testKey())
	require.NoError(t, err)
	other, err := secret.NewSealer(bytes.Repeat([]byte{9}, 32))
	require.NoError(t, err)
	box, err := sealer.Seal([]byte("api-key"), nil)
	require.NoError(t, err)

	_, err = other.Open(box, nil)

	assert.Error(t, err, "the database file alone is not enough to read a key")
}

func TestNewSealerRejectsWrongKeySizes(t *testing.T) {
	_, err := secret.NewSealer([]byte("too short"))

	assert.Error(t, err)
}

func flip(box []byte) []byte {
	tampered := append([]byte(nil), box...)
	tampered[len(tampered)-1] ^= 0xff
	return tampered
}
