package core

import (
	"context"
	"errors"
)

func (engine *nativeEngine) nativeSeasonMetadata(ctx context.Context, drama nativeDrama) (any, error) {
	source, id, valid := splitProviderDramaID(drama.ID)
	if !valid || source != sourceHongguo || !nativeDramaAvailable(drama) || !hongguoNumericID.MatchString(id) {
		return nil, errors.New("续季剧集信息无效")
	}
	raw, err := engine.downloader.hongguoWebSeriesMetadata(ctx, id)
	if err != nil {
		return nil, err
	}
	if raw.ID != drama.ID {
		return nil, errors.New("续季剧集信息不一致")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	fresh := mergeNativeDrama(drama, nativeNormalize(raw))
	return map[string]any{"drama": fresh}, nil
}
