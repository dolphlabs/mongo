package main

import (
	"fmt"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
)

func document() bson.D {
	return bson.D{
		{Key: "_id", Value: int32(42)},
		{Key: "name", Value: "Ada Lovelace"},
		{Key: "active", Value: true},
		{Key: "score", Value: float64(98.75)},
		{Key: "createdAt", Value: primitive.DateTime(1700000000123)},
		{Key: "roles", Value: bson.A{"admin", "billing"}},
		{Key: "profile", Value: bson.D{
			{Key: "city", Value: "Lagos"},
			{Key: "country", Value: "NG"},
		}},
	}
}

func wideDocument() bson.D {
	doc := make(bson.D, 0, 128)
	for i := 0; i < 128; i++ {
		doc = append(doc, bson.E{Key: fmt.Sprintf("field_%d", i), Value: int32(i)})
	}
	return doc
}

func wireHash(raw []byte) int64 {
	var hash int64
	for _, b := range raw {
		hash = (hash*31 + int64(b)) % 1000000007
	}
	return hash
}

func benchmark(label string, doc bson.D, iterations int) {
	baseline, err := bson.Marshal(doc)
	if err != nil {
		panic(err)
	}

	var encodeChecksum int
	start := time.Now()
	for i := 0; i < iterations; i++ {
		raw, err := bson.Marshal(doc)
		if err != nil {
			panic(err)
		}
		encodeChecksum += len(raw)
	}
	encodeNS := time.Since(start).Nanoseconds() / int64(iterations)

	var decodeChecksum int
	start = time.Now()
	for i := 0; i < iterations; i++ {
		var decoded bson.D
		if err := bson.Unmarshal(baseline, &decoded); err != nil {
			panic(err)
		}
		decodeChecksum += len(decoded)
	}
	decodeNS := time.Since(start).Nanoseconds() / int64(iterations)

	fmt.Printf("codec=go shape=%s bson_bytes=%d wire_hash=%d iterations=%d\n", label, len(baseline), wireHash(baseline), iterations)
	fmt.Printf("encode_ns_op=%d checksum=%d\n", encodeNS, encodeChecksum)
	fmt.Printf("decode_ns_op=%d checksum=%d\n", decodeNS, decodeChecksum)
}

func main() {
	benchmark("small", document(), 20000)
	benchmark("wide128", wideDocument(), 1000)
}
