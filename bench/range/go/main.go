package main

import (
	"context"
	"flag"
	"fmt"
	"sort"
	"sync"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

const (
	rangeCount   = 50
	payloadBytes = 1024
)

type workerResult struct {
	latencies []int64
	checks    int
	err       error
}

func rangeOnce(ctx context.Context, col *mongo.Collection, worker int) (int, error) {
	filter := bson.D{{Key: "tenant_id", Value: int32(worker % 1000)}}
	findOptions := options.Find().SetSort(bson.D{{Key: "seq", Value: 1}}).
		SetLimit(rangeCount).SetBatchSize(rangeCount)
	cur, err := col.Find(ctx, filter, findOptions)
	if err != nil {
		return 0, err
	}
	defer cur.Close(ctx)

	count := 0
	lastSeq := int64(-1)
	for cur.Next(ctx) {
		var row bson.M
		if err := cur.Decode(&row); err != nil {
			return count, err
		}
		tenant, ok := integer(row["tenant_id"])
		if !ok {
			return count, fmt.Errorf("tenant_id has type %T", row["tenant_id"])
		}
		seq, ok := integer(row["seq"])
		if !ok {
			return count, fmt.Errorf("seq has type %T", row["seq"])
		}
		payload, ok := row["payload"].(string)
		if tenant != int64(worker%1000) || seq <= lastSeq || !ok || len(payload) != payloadBytes {
			return count, fmt.Errorf("range correctness check failed: tenant=%d seq=%d payload_bytes=%d",
				tenant, seq, len(payload))
		}
		lastSeq = seq
		count++
	}
	if err := cur.Err(); err != nil {
		return count, err
	}
	if count != rangeCount {
		return count, fmt.Errorf("range returned %d documents, want %d", count, rangeCount)
	}
	return count, nil
}

func integer(value any) (int64, bool) {
	switch v := value.(type) {
	case int32:
		return int64(v), true
	case int64:
		return v, true
	case int:
		return int64(v), true
	default:
		return 0, false
	}
}

func workerLoop(ctx context.Context, col *mongo.Collection, id, ops int,
	ready chan<- struct{}, start <-chan struct{}, out chan<- workerResult) {
	local := workerResult{latencies: make([]int64, 0, ops)}
	for i := 0; i < 5; i++ {
		callCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		_, err := rangeOnce(callCtx, col, id)
		cancel()
		if err != nil {
			local.err = fmt.Errorf("warmup worker %d: %w", id, err)
			ready <- struct{}{}
			<-start
			out <- local
			return
		}
	}
	ready <- struct{}{}
	<-start
	for i := 0; i < ops; i++ {
		callCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		began := time.Now()
		checks, err := rangeOnce(callCtx, col, id)
		elapsed := time.Since(began).Nanoseconds()
		cancel()
		if err != nil {
			local.err = fmt.Errorf("worker %d op %d: %w", id, i, err)
			break
		}
		local.latencies = append(local.latencies, elapsed)
		local.checks += checks
	}
	out <- local
}

func percentile(values []int64, p int) int64 {
	index := (len(values)*p+99)/100 - 1
	if index < 0 {
		index = 0
	}
	return values[index]
}

func run(uri, database string, workers, ops int) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	client, err := mongo.Connect(ctx,
		options.Client().ApplyURI(uri).SetMaxPoolSize(uint64(workers)))
	if err != nil {
		cancel()
		return err
	}
	if err := client.Ping(ctx, nil); err != nil {
		cancel()
		_ = client.Disconnect(context.Background())
		return err
	}
	cancel()
	defer client.Disconnect(context.Background())

	col := client.Database(database).Collection("events")
	ready := make(chan struct{}, workers)
	start := make(chan struct{}, workers)
	out := make(chan workerResult, workers)
	var wg sync.WaitGroup
	for id := 0; id < workers; id++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			workerLoop(context.Background(), col, id, ops, ready, start, out)
		}(id)
	}
	for i := 0; i < workers; i++ {
		<-ready
	}
	started := time.Now()
	for i := 0; i < workers; i++ {
		start <- struct{}{}
	}
	wg.Wait()
	elapsed := time.Since(started)
	close(out)

	latencies := make([]int64, 0, workers*ops)
	checks := 0
	for result := range out {
		if result.err != nil {
			return result.err
		}
		latencies = append(latencies, result.latencies...)
		checks += result.checks
	}
	if len(latencies) != workers*ops {
		return fmt.Errorf("completed %d operations, want %d", len(latencies), workers*ops)
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	throughput := int64(len(latencies)) * int64(time.Second) / elapsed.Nanoseconds()
	fmt.Printf("RESULT lang=go workers=%d ops=%d elapsed_ns=%d throughput_ops_s=%d p50_ns=%d p95_ns=%d p99_ns=%d checks=%d errors=0\n",
		workers, len(latencies), elapsed.Nanoseconds(), throughput,
		percentile(latencies, 50), percentile(latencies, 95),
		percentile(latencies, 99), checks)
	return nil
}

func main() {
	uri := flag.String("uri", "mongodb://127.0.0.1:27017", "MongoDB URI")
	database := flag.String("database", "slang_mongo_bench_20261011", "existing benchmark database")
	workers := flag.Int("workers", 1, "concurrent workers")
	ops := flag.Int("ops", 100, "operations per worker")
	flag.Parse()
	if *workers < 1 || *ops < 1 {
		panic("workers and ops must be positive")
	}
	if err := run(*uri, *database, *workers, *ops); err != nil {
		panic(err)
	}
}
