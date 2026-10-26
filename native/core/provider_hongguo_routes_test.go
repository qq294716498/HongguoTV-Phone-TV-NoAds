package core

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestHongguoPlaybackRouteBudgets(t *testing.T) {
	for _, scenario := range []struct {
		name       string
		background bool
		first      time.Duration
	}{
		{name: "foreground", first: 9 * time.Second},
		{name: "preload", background: true, first: 6 * time.Second},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			ctx = context.WithValue(ctx, backgroundCatalogKey{}, scenario.background)
			media, err := resolveHongguoMediaRoutes(ctx, []hongguoMediaRoute{
				{name: "app", resolve: func(stage context.Context) (providerMedia, error) {
					deadline, exists := stage.Deadline()
					remaining := time.Until(deadline)
					if !exists || remaining > scenario.first || remaining < scenario.first-100*time.Millisecond {
						t.Fatalf("unexpected first-stage budget: %s", remaining)
					}
					return providerMedia{URL: "https://synthetic.example/episode.mp4"}, nil
				}},
				{name: "web", resolve: func(context.Context) (providerMedia, error) {
					t.Fatal("successful App route fell through")
					return providerMedia{}, nil
				}},
				{name: "api", resolve: func(context.Context) (providerMedia, error) {
					t.Fatal("successful App route fell through")
					return providerMedia{}, nil
				}},
			})
			if err != nil || media.URL == "" {
				t.Fatalf("successful route failed: %v", err)
			}
		})
	}
}

func TestHongguoStageTimeoutReservesBackupRoutes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	var calls []string
	wait := func(name string) hongguoMediaRoute {
		return hongguoMediaRoute{name: name, resolve: func(stage context.Context) (providerMedia, error) {
			calls = append(calls, name)
			<-stage.Done()
			return providerMedia{}, stage.Err()
		}}
	}
	media, err := resolveHongguoMediaRoutes(ctx, []hongguoMediaRoute{
		wait("app"), wait("web"),
		{name: "api", resolve: func(stage context.Context) (providerMedia, error) {
			calls = append(calls, "api")
			if err := stage.Err(); err != nil {
				t.Fatalf("backup received expired context: %v", err)
			}
			return providerMedia{URL: "https://synthetic.example/backup.mp4"}, nil
		}},
	})
	if err != nil || media.URL == "" || strings.Join(calls, ",") != "app,web,api" {
		t.Fatalf("backup was starved: calls=%v error=%v", calls, err)
	}
}

func TestHongguoParentCancellationStopsFallback(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	_, err := resolveHongguoMediaRoutes(ctx, []hongguoMediaRoute{
		{name: "app", resolve: func(stage context.Context) (providerMedia, error) {
			calls++
			cancel()
			<-stage.Done()
			return providerMedia{}, stage.Err()
		}},
		{name: "web", resolve: func(context.Context) (providerMedia, error) {
			calls++
			return providerMedia{}, errors.New("unexpected fallback")
		}},
	})
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatalf("canceled playback continued fallback: calls=%d error=%v", calls, err)
	}
}

func TestHongguoRateLimitStopsFallbackAndPreservesBackoff(t *testing.T) {
	blocked := &requestBackoff{host: "synthetic.example", status: 429, until: time.Now().Add(time.Minute)}
	calls := 0
	_, err := resolveHongguoMediaRoutes(context.Background(), []hongguoMediaRoute{
		{name: "app", resolve: func(context.Context) (providerMedia, error) {
			calls++
			return providerMedia{}, blocked
		}},
		{name: "web", resolve: func(context.Context) (providerMedia, error) {
			calls++
			return providerMedia{}, errors.New("unexpected fallback")
		}},
	})
	var retained *requestBackoff
	if calls != 1 || !errors.As(err, &retained) || retained != blocked {
		t.Fatalf("rate limit was ignored or lost: calls=%d error=%v", calls, err)
	}
}

func TestHongguoForbiddenAllowsIndependentFallback(t *testing.T) {
	blocked := &requestBackoff{host: "synthetic.example", status: 403, until: time.Now().Add(time.Minute)}
	calls := 0
	media, err := resolveHongguoMediaRoutes(context.Background(), []hongguoMediaRoute{
		{name: "app", resolve: func(context.Context) (providerMedia, error) {
			calls++
			return providerMedia{}, blocked
		}},
		{name: "web", resolve: func(context.Context) (providerMedia, error) {
			calls++
			return providerMedia{URL: "https://independent.example/episode.mp4"}, nil
		}},
	})
	if err != nil || media.URL == "" || calls != 2 {
		t.Fatalf("independent fallback was suppressed: calls=%d error=%v", calls, err)
	}
}

func TestHongguoFailedRoutesPreserveEarlierBackoff(t *testing.T) {
	blocked := &requestBackoff{host: "synthetic.example", status: 403, until: time.Now().Add(time.Minute)}
	webFailure, apiFailure := errors.New("web failed"), errors.New("api failed")
	_, err := resolveHongguoMediaRoutes(context.Background(), []hongguoMediaRoute{
		{name: "app", resolve: func(context.Context) (providerMedia, error) { return providerMedia{}, blocked }},
		{name: "web", resolve: func(context.Context) (providerMedia, error) { return providerMedia{}, webFailure }},
		{name: "api", resolve: func(context.Context) (providerMedia, error) { return providerMedia{}, apiFailure }},
	})
	var retained *requestBackoff
	if !errors.As(err, &retained) || retained != blocked || !errors.Is(err, webFailure) || !errors.Is(err, apiFailure) {
		t.Fatalf("route errors lost their identity: %v", err)
	}
}
