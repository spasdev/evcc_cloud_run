package core

import (
	"maps"
	"math"
	"slices"
	"time"

	"github.com/evcc-io/evcc/api"
	"github.com/evcc-io/evcc/core/keys"
	"github.com/evcc-io/evcc/server/db/settings"
	"github.com/evcc-io/evcc/tariff"
	"github.com/jinzhu/now"
	"github.com/samber/lo"
)

type solarDetails struct {
	Scale            *float64     `json:"scale,omitempty"`            // scale factor yield/forecasted today
	Today            dailyDetails `json:"today,omitempty"`            // tomorrow
	Tomorrow         dailyDetails `json:"tomorrow,omitempty"`         // tomorrow
	DayAfterTomorrow dailyDetails `json:"dayAfterTomorrow,omitempty"` // day after tomorrow
	Timeseries       []tsEntry    `json:"timeseries,omitempty"`       // timeseries of forecasted energy
}

type dailyDetails struct {
	Yield    float64 `json:"energy"`
	Complete bool    `json:"complete"`
}

// greenShare returns
//   - the current green share, calculated for the part of the consumption between powerFrom and powerTo
//     the consumption below powerFrom will get the available green power first
func (site *Site) greenShare(powerFrom float64, powerTo float64) float64 {
	greenPower := math.Max(0, site.pvPower) + math.Max(0, site.batteryPower)
	greenPowerAvailable := math.Max(0, greenPower-powerFrom)

	power := powerTo - powerFrom
	share := math.Min(greenPowerAvailable, power) / power

	if math.IsNaN(share) {
		if greenPowerAvailable > 0 {
			share = 1
		} else {
			share = 0
		}
	}

	return share
}

// effectivePrice calculates the real energy price based on self-produced and grid-imported energy.
func (site *Site) effectivePrice(greenShare float64) *float64 {
	if grid, err := tariff.Now(site.GetTariff(api.TariffUsageGrid)); err == nil {
		feedin, err := tariff.Now(site.GetTariff(api.TariffUsageFeedIn))
		if err != nil {
			feedin = 0
		}
		effPrice := grid*(1-greenShare) + feedin*greenShare
		return &effPrice
	}
	return nil
}

// effectiveTariffImpl implements api.Tariff for a static set of rates
type effectiveTariffImpl struct {
	rates api.Rates
}

func (t *effectiveTariffImpl) Rates() (api.Rates, error) {
	return t.rates, nil
}

func (t *effectiveTariffImpl) Type() api.TariffType {
	return api.TariffType(api.TariffUsagePlanner)
}

// NewEffectiveTariff returns a Tariff implementation with the provided rates
func NewEffectiveTariff(rates api.Rates) api.Tariff {
	return &effectiveTariffImpl{rates: rates}
}

// Calculate Effective Forecasted Tariffs computes the real energy price based on forecasted self-produced and grid-imported energy.
func (site *Site) CalculateEffectiveForecastedTariffs(lp *Loadpoint) api.Tariff {
	// get solar forecast from tariff object
	forecastedGreenObj := site.GetTariff(api.TariffUsageSolar)

	if forecastedGreenObj == nil {
		// no solar forecast available then return the default tariff
		return site.GetTariff(api.TariffUsagePlanner)
	}

	forecastedGreen := []api.Rate{}
	forecastedGreen = tariff.Forecast(forecastedGreenObj)

	// get grid rates from tariff object
	gridTariffObj := site.GetTariff(api.TariffUsageGrid)

	gridRates := []api.Rate{}

	// if no grid tariff available then return the default tariff
	if gridTariffObj != nil {
		gridRates = tariff.Forecast(gridTariffObj)
	} else {
		return site.GetTariff(api.TariffUsagePlanner)
	}

	// get feed-in tariff from tariff object
	feedInTariffObj := site.GetTariff(api.TariffUsageFeedIn)
	feedInRates := []api.Rate{}

	// if feedInTariffObj is fixed (not dynamic) then extend the value to all rates (same price at all time)
	if feedInTariffObj != nil && feedInTariffObj.Type() == api.TariffTypePriceStatic {
		feedIn, err := tariff.Now(feedInTariffObj)
		if err == nil {
			feedInRates = make([]api.Rate, len(gridRates))
			for i := range gridRates {
				feedInRates[i] = api.Rate{
					Start: gridRates[i].Start,
					End:   gridRates[i].End,
					Value: feedIn,
				}
			}
		}
	} else if feedInTariffObj != nil && feedInTariffObj.Type() == api.TariffTypePriceDynamic {
		// otherwise use the dynamic feedIn rates as they are
		feedInRates = tariff.Forecast(feedInTariffObj)
	} else {
		// no feed-in tariff available then return the default tariff as one can't compute effective tariff
		return site.GetTariff(api.TariffUsagePlanner)
	}
	// align the 3 rates slices to have same time slots
	// this is needed as the rates may have with different time slots patterns
	// and we need to have the same time slots to compute the effective tariff
	alignRates(&gridRates, &forecastedGreen)
	alignRates(&gridRates, &feedInRates)

	effectiveTariffs := make([]api.Rate, 0, len(gridRates))

	// now compute the effective tariff for each time slot
	// the effective tariff is computed as:
	// effectiveTariff = gridTariff * proportionOfGridPower + feedInTariff * proportionOfGreenPower
	// to set proportionOfGreenPower we use the forecasted green power and the loadpoint max power and
	// we compute the potential proportion of green power that can be used by the loadpoint at this
	// specific time slot
	for i := range gridRates {
		if i >= len(forecastedGreen) || i >= len(feedInRates) {
			break
		}

		proportionOfGreenPower := 0.0

		// if there some forecasted green power than compute the proportion, otherwise stays zero
		if forecastedGreen[i].Value > 0 {
			// scale maxpower to the duration of the slot at forecastedGreen[i]
			slotDuration := forecastedGreen[i].End.Sub(forecastedGreen[i].Start).Seconds()
			referenceDuration := 3600.0 // reference: 1 hour in seconds
			scaledMaxPower := lp.effectiveMaxPower() * (slotDuration / referenceDuration)
			proportionOfGreenPower = forecastedGreen[i].Value / scaledMaxPower
		}

		// and if more green power than needed then limit to 100% Green Power
		if proportionOfGreenPower > 1.0 {
			proportionOfGreenPower = 1.0
		}

		proportionOfGridPower := 1.0 - proportionOfGreenPower

		gridTariff := gridRates[i].Value
		feedInTariff := feedInRates[i].Value

		effectiveTariff := (gridTariff * proportionOfGridPower) + (feedInTariff * proportionOfGreenPower)
		effectiveTariffs = append(effectiveTariffs, api.Rate{
			Start: gridRates[i].Start,
			End:   gridRates[i].End,
			Value: effectiveTariff,
		})
	}

	// take effectiveTariffs and create a api.Tariff Planner
	return NewEffectiveTariff(effectiveTariffs)
}

// alignRates ensures two []api.Rate slices cover the same time slots.
// If slots are missing, it interpolates values using linear interpolation and adjusts cumulative values proportionally to slot duration.
func alignRates(a, b *[]api.Rate) {
	if len(*a) == 0 || len(*b) == 0 {
		return
	}

	// Collect all unique slot boundaries
	boundaries := map[time.Time]struct{}{}
	for _, r := range *a {
		boundaries[r.Start] = struct{}{}
		boundaries[r.End] = struct{}{}
	}
	for _, r := range *b {
		boundaries[r.Start] = struct{}{}
		boundaries[r.End] = struct{}{}
	}

	// Sort boundaries
	var slots []time.Time
	for k := range boundaries {
		slots = append(slots, k)
	}
	slices.SortFunc(slots, func(x, y time.Time) int {
		if x.Before(y) {
			return -1
		}
		if x.After(y) {
			return 1
		}
		return 0
	})

	// Helper to interpolate cumulative value at a given time
	interpolateCumulative := func(rates []api.Rate, start, end time.Time) float64 {
		for _, r := range rates {
			if !start.Before(r.Start) && !end.After(r.End) {
				origDuration := r.End.Sub(r.Start).Seconds()
				newDuration := end.Sub(start).Seconds()
				if origDuration > 0 {
					return r.Value * (newDuration / origDuration)
				}
				return 0
			}
		}
		// Linear interpolation between closest slots (fallback)
		for i := 1; i < len(rates); i++ {
			if start.Before(rates[i].Start) && end.After(rates[i-1].End) {
				origDuration := rates[i].Start.Sub(rates[i-1].End).Seconds()
				newDuration := end.Sub(start).Seconds()
				if origDuration > 0 {
					avgValue := (rates[i-1].Value + rates[i].Value) / 2
					return avgValue * (newDuration / origDuration)
				}
			}
		}
		return 0 // fallback
	}

	// Build aligned slices with proportional cumulative values
	alignedA := make([]api.Rate, 0, len(slots)-1)
	alignedB := make([]api.Rate, 0, len(slots)-1)
	for i := 0; i < len(slots)-1; i++ {
		start := slots[i]
		end := slots[i+1]
		alignedA = append(alignedA, api.Rate{
			Start: start,
			End:   end,
			Value: interpolateCumulative(*a, start, end),
		})
		alignedB = append(alignedB, api.Rate{
			Start: start,
			End:   end,
			Value: interpolateCumulative(*b, start, end),
		})
	}

	*a = alignedA
	*b = alignedB
}

// effectiveCo2 calculates the amount of emitted co2 based on self-produced and grid-imported energy.
func (site *Site) effectiveCo2(greenShare float64) *float64 {
	if co2, err := tariff.Now(site.GetTariff(api.TariffUsageCo2)); err == nil {
		effCo2 := co2 * (1 - greenShare)
		return &effCo2
	}
	return nil
}

func (site *Site) publishTariffs(greenShareHome float64, greenShareLoadpoints float64) {
	site.publish(keys.GreenShareHome, greenShareHome)
	site.publish(keys.GreenShareLoadpoints, greenShareLoadpoints)

	if v, err := tariff.Now(site.GetTariff(api.TariffUsageGrid)); err == nil {
		site.publish(keys.TariffGrid, v)
	}
	if v, err := tariff.Now(site.GetTariff(api.TariffUsageFeedIn)); err == nil {
		site.publish(keys.TariffFeedIn, v)
	}
	if v, err := tariff.Now(site.GetTariff(api.TariffUsageCo2)); err == nil {
		site.publish(keys.TariffCo2, v)
	}
	if v, err := tariff.Now(site.GetTariff(api.TariffUsageSolar)); err == nil {
		site.publish(keys.TariffSolar, v)
	}
	if v := site.effectivePrice(greenShareHome); v != nil {
		site.publish(keys.TariffPriceHome, v)
	}
	if v := site.effectiveCo2(greenShareHome); v != nil {
		site.publish(keys.TariffCo2Home, v)
	}
	if v := site.effectivePrice(greenShareLoadpoints); v != nil {
		site.publish(keys.TariffPriceLoadpoints, v)
	}
	if v := site.effectiveCo2(greenShareLoadpoints); v != nil {
		site.publish(keys.TariffCo2Loadpoints, v)
	}

	fc := struct {
		Co2     api.Rates     `json:"co2,omitempty"`
		FeedIn  api.Rates     `json:"feedin,omitempty"`
		Grid    api.Rates     `json:"grid,omitempty"`
		Planner api.Rates     `json:"planner,omitempty"`
		Solar   *solarDetails `json:"solar,omitempty"`
	}{
		Co2:     tariff.Forecast(site.GetTariff(api.TariffUsageCo2)),
		FeedIn:  tariff.Forecast(site.GetTariff(api.TariffUsageFeedIn)),
		Planner: tariff.Forecast(site.GetTariff(api.TariffUsagePlanner)),
		Grid:    tariff.Forecast(site.GetTariff(api.TariffUsageGrid)),
	}

	// calculate adjusted solar forecast
	if solar := tariff.Forecast(site.GetTariff(api.TariffUsageSolar)); len(solar) > 0 {
		fc.Solar = lo.ToPtr(site.solarDetails(solar))
	}

	site.publish(keys.Forecast, fc)
}

func (site *Site) solarDetails(solar api.Rates) solarDetails {
	res := solarDetails{
		Timeseries: solarTimeseries(solar),
	}

	last := solar[len(solar)-1].Start

	bod := now.BeginningOfDay()
	eod := bod.AddDate(0, 0, 1)
	eot := eod.AddDate(0, 0, 1)

	remainingToday := solarEnergy(solar, time.Now(), eod)
	tomorrow := solarEnergy(solar, eod, eot)
	dayAfterTomorrow := solarEnergy(solar, eot, eot.AddDate(0, 0, 1))

	res.Today = dailyDetails{
		Yield:    remainingToday,
		Complete: !last.Before(eod),
	}
	res.Tomorrow = dailyDetails{
		Yield:    tomorrow,
		Complete: !last.Before(eot),
	}
	res.DayAfterTomorrow = dailyDetails{
		Yield:    dayAfterTomorrow,
		Complete: !last.Before(eot.AddDate(0, 0, 1)),
	}

	// accumulate forecasted energy since last update
	energy := solarEnergy(solar, site.fcstEnergy.updated, time.Now()) / 1e3
	site.log.DEBUG.Printf("solar forecast: accumulated %.3fWh from %v to %v",
		energy, site.fcstEnergy.updated.Truncate(time.Second), time.Now().Truncate(time.Second),
	)

	site.fcstEnergy.AddEnergy(energy)
	settings.SetFloat(keys.SolarAccForecast, site.fcstEnergy.Accumulated)

	produced := lo.SumBy(slices.Collect(maps.Values(site.pvEnergy)), func(v *meterEnergy) float64 {
		return v.AccumulatedEnergy()
	})
	site.log.DEBUG.Printf("solar forecast: produced %.3f", produced)

	if fcst := site.fcstEnergy.AccumulatedEnergy(); fcst > 0 {
		scale := produced / fcst
		site.log.DEBUG.Printf("solar forecast: accumulated %.3fkWh, produced %.3fkWh, scale %.3f", fcst, produced, scale)

		const minEnergy = 0.5 // kWh
		if produced+fcst > minEnergy {
			res.Scale = lo.ToPtr(scale)
		}
	}

	return res
}

func (site *Site) isDynamicTariff(usage api.TariffUsage) bool {
	tariff := site.GetTariff(usage)
	return tariff != nil && tariff.Type() != api.TariffTypePriceStatic
}
