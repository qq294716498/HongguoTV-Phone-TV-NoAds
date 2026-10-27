package core

import (
	"context"
	"errors"
	"fmt"
	"time"
)

const (
	hongguoPlaybackBudget = 30 * time.Second
	hongguoPreloadBudget  = 12 * time.Second
	hongguoDownloadBudget = 45 * time.Second
)

type hongguoDownloadKey struct{}

type hongguoMediaRoute struct {
	name    string
	resolve func(context.Context) (providerMedia, error)
}

func resolveHongguoMediaRoutes(ctx context.Context, routes []hongguoMediaRoute) (providerMedia, error) {
	parent := ctx
	budget := hongguoPlaybackBudget
	background, _ := ctx.Value(backgroundCatalogKey{}).(bool)
	if background {
		budget = hongguoPreloadBudget
	}
	download, _ := ctx.Value(hongguoDownloadKey{}).(bool)
	if download {
		budget = hongguoDownloadBudget
	}
	ctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	deadline, _ := ctx.Deadline()
	var failures []error
	for index, route := range routes {
		if err := parent.Err(); err != nil {
			return providerMedia{}, err
		}
		if err := ctx.Err(); err != nil {
			failures = append(failures, err)
			break
		}
		remainingRoutes := len(routes) - index
		weight := 1
		if index == 0 && remainingRoutes > 1 {
			weight = 2
			if download || !background {
				weight = 8
			}
			remainingRoutes += weight - 1
		}
		stage, finish := context.WithTimeout(ctx, time.Until(deadline)*time.Duration(weight)/time.Duration(remainingRoutes))
		media, err := route.resolve(stage)
		if err == nil {
			err = stage.Err()
		}
		finish()
		if parentErr := parent.Err(); parentErr != nil {
			return providerMedia{}, parentErr
		}
		if totalErr := ctx.Err(); totalErr != nil {
			err = errors.Join(err, totalErr)
		}
		if err == nil {
			return media, nil
		}
		failure := fmt.Errorf("%s：%w", route.name, err)
		var blocked *requestBackoff
		if errors.As(err, &blocked) && blocked.status == 429 || errors.Is(err, context.Canceled) {
			return providerMedia{}, failure
		}
		failures = append(failures, failure)
	}
	return providerMedia{}, fmt.Errorf("红果取流失败：%w", errors.Join(failures...))
}
