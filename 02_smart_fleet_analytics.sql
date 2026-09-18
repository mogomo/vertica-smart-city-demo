--
-- =====================================================================================
--  VERTICA SMART FLEET DEMO  -  part 2 of 3 : geospatial analytics + in-database ML
-- =====================================================================================
--  Autonomous vs. human-driven city buses.   Prerequisite: 01_smart_fleet_setup.sql
--
--  Run:        /opt/vertica/bin/vsql -f 02_smart_fleet_analytics.sql
--  Live demo:  DEMO_PAUSE=1 /opt/vertica/bin/vsql -f 02_smart_fleet_analytics.sql     (waits for ENTER between acts)
--
--  Who should care:   [OPS]  fleet operator      [CITY] smart-city municipality
--                     [911]  emergency response  [OEM]  EV / AV manufacturer
--
--  All data is synthetic (see part 1). This is a demo - it is not intended to run in production.
--
set search_path to FLEET, public;
\timing off

-- Housekeeping: this script can be re-run; clear everything it creates (marts, views, models) in one quiet block.
-- On the first run after part 1 Vertica answers each of these with a harmless "NOTICE: Nothing was dropped".
\o /dev/null
drop view if exists vehicle_style_norm;
drop view if exists iforest_input;
drop view if exists energy_model_input;
drop table if exists zone_hits cascade;
drop table if exists vehicle_day cascade;
drop table if exists segment_scorecard cascade;
drop table if exists vehicle_score cascade;
drop table if exists vehicle_style cascade;
drop table if exists pdm_features cascade;
drop table if exists pdm_test_scored cascade;
drop table if exists pdm_work_orders cascade;
drop table if exists scenario cascade;
drop table if exists scenario_positions cascade;
drop table if exists exec_kpi cascade;
drop model if exists fleet_style_norm;
drop model if exists fleet_style_kmeans;
drop model if exists fleet_pdm_rf;
drop model if exists fleet_iforest;
drop model if exists fleet_energy_lr;
\o

\! tput rev 2>/dev/null; echo " VERTICA SMART FLEET DEMO | part 2: from raw IoT events to decisions - in SQL, inside the database "; tput sgr0 2>/dev/null
\echo ''
\echo '   ACT 1  The IoT stream ............. time-series SQL: latest state, gap filling, interpolation'
\echo '   ACT 2  Where it happens ........... geospatial: geofences, route adherence, black spots'
\echo '   ACT 3  Autonomous vs. human ....... safety scorecard, driver coaching, event pattern matching'
\echo '   ACT 4  Energy ..................... kWh/km, regeneration, temperature, idling, CO2, money'
\echo '   ACT 5  Machine learning ........... driving-style clusters, predictive maintenance, anomalies'
\echo '   ACT 6  Emergency response ......... nearest units, hospital routing, green corridor'
\echo '   ACT 7  Executive summary'
\echo ''

-- =====================================================================================
\! [ -n "$DEMO_PAUSE" ] && { echo; printf "%s" ">>> press ENTER for ACT 1 ... "; read x; } ; echo; tput rev 2>/dev/null; echo " ACT 1 | THE IoT STREAM                                                            "; tput sgr0 2>/dev/null
-- =====================================================================================
select to_char(count(*), '999,999,999') as iot_events, count(distinct vehicle_id) as vehicles,
       min(ts)::date as from_day, max(ts)::date as to_day
from telemetry;

\echo '>>> One raw event, as sent by the vehicle gateway:'
\x
select * from telemetry where vehicle_id = 1002 and speed_kmh > 20 order by ts desc limit 1;
\x

\echo '>>> [OPS] Live fleet board: the LATEST state of every vehicle - Vertica Top-K:  LIMIT 1 OVER (PARTITION BY ...)'
\timing on
select v.plate, v.fleet_segment, r.line_no as line, to_char(l.ts, 'HH24:MI:SS') as last_seen,
       l.lat, l.lon, l.speed_kmh, l.passengers as pax, l.energy_pct as "energy %",
       repeat('█', (l.energy_pct / 10)::int) || repeat('░', 10 - (l.energy_pct / 10)::int) as "battery / tank"
from (select * from telemetry limit 1 over (partition by vehicle_id order by ts desc)) l
     join vehicles v using (vehicle_id) join routes r using (route_id)
order by l.energy_pct limit 10;
\timing off

\echo '>>> [OPS] Sensors are irregular and messages get lost: bus TLV-1001 drove through a tunnel (16:00-16:08, no GPS).'
\echo '>>>       Raw events around the gap:'
select to_char(ts, 'HH24:MI:SS') as ts, lat, lon, speed_kmh, energy_pct
from telemetry
where vehicle_id = 1001 and ts between (select max(ts)::date + interval '15:57' from telemetry) and (select max(ts)::date + interval '16:12' from telemetry)
order by 1;

\echo '>>>       Same window through the TIMESERIES clause: a perfect 1-minute grid, positions linearly interpolated (TS_FIRST_VALUE ... LINEAR)'
select to_char(g.slice, 'HH24:MI') as minute, g.lat, g.lon, g.speed_kmh, g.energy_pct,
       case when r.minute is null then '<-- no message: gap filled' else '' end as " "
from (select slice,
             ts_first_value(lat, 'LINEAR')::numeric(9,6)       as lat,
             ts_first_value(lon, 'LINEAR')::numeric(9,6)       as lon,
             ts_first_value(speed_kmh, 'LINEAR')::numeric(5,1) as speed_kmh,
             ts_first_value(energy_pct, 'LINEAR')::numeric(5,1) as energy_pct
      from telemetry
      where vehicle_id = 1001 and ts between (select max(ts)::date + interval '15:58' from telemetry) and (select max(ts)::date + interval '16:12' from telemetry)
      timeseries slice as '1 minute' over (partition by vehicle_id order by ts)) g
left join (select distinct date_trunc('minute', ts) as minute from telemetry
           where vehicle_id = 1001 and ts >= (select max(ts)::date from telemetry)) r on r.minute = g.slice
order by 1;

-- =====================================================================================
\! [ -n "$DEMO_PAUSE" ] && { echo; printf "%s" ">>> press ENTER for ACT 2 ... "; read x; } ; echo; tput rev 2>/dev/null; echo " ACT 2 | WHERE IT HAPPENS - GEOSPATIAL ANALYTICS AT IoT SCALE                        "; tput sgr0 2>/dev/null
-- =====================================================================================
\echo '>>> The map layers: 12 bus lines (LINESTRING), 21 geofences (POLYGON), hospitals / depots / chargers (POINT)'
select zone_type, count(*) as zones, min(speed_limit_kmh) as "limit km/h",
       (sum(ST_Area(ST_GeographyFromText(ST_AsText(zone_geom)))) / 1e6)::numeric(8,2) as "area km2",
       min(ST_NumPoints(zone_geom)) as polygon_vertices
from zones group by 1 order by 1;

\echo '>>> Build spatial indexes on the geofences (STV_Create_Index). One for speed-regulated zones, one for all zones.'
select STV_Create_Index(zone_id, zone_geom using parameters index = 'fleet_speed_zones', overwrite = true) over ()
from zones where zone_type in ('SCHOOL', 'HOSPITAL', 'DEPOT');
select STV_Create_Index(zone_id, zone_geom using parameters index = 'fleet_all_zones', overwrite = true) over ()
from zones;

\echo '>>> Geofence EVERY GPS point of the fleet against ALL polygons (STV_Intersect, parallel on all cores):'
create table zone_hits (event_id int not null, zone_id int not null) order by event_id segmented by hash(event_id) all nodes;
\timing on
insert into zone_hits
select STV_Intersect(event_id, STV_GeometryPoint(lon, lat) using parameters index = 'fleet_all_zones')
       over (partition best) as (event_id, zone_id)
from telemetry;
commit;
\timing off
select to_char(t.n, '999,999,999') as gps_points_tested, z.n as polygons, to_char(h.n, '999,999,999') as point_in_polygon_hits
from (select count(*) as n from telemetry) t, (select count(*) as n from zones) z, (select count(*) as n from zone_hits) h;

\echo '>>> [CITY] School zones, school hours (07:00-17:00), limit 30 km/h: who respects them?'
\echo '>>>        Here STV_Intersect is used as an inline scalar function - no join, no pre-processing.'
\timing on
with in_zone as (
   select t.vehicle_id, t.speed_kmh,
          STV_Intersect(STV_GeometryPoint(t.lon, t.lat) using parameters index = 'fleet_speed_zones') as zone_id
   from telemetry t
   where hour(t.ts) between 7 and 16 and t.speed_kmh > 0
)
select v.drive_mode,
       to_char(count(*), '9,999,999')                                                       as readings_in_school_zones,
       sum(case when z.speed_kmh > 33 then 1 else 0 end)                                    as "over 33 km/h",
       sum(case when z.speed_kmh > 45 then 1 else 0 end)                                    as "over 45 km/h",
       max(z.speed_kmh)                                                                     as max_kmh,
       (100.0 * sum(case when z.speed_kmh > 33 then 1 else 0 end) / count(*))::numeric(5,2) as violation_pct,
       repeat('█', (100.0 * sum(case when z.speed_kmh > 33 then 1 else 0 end) / count(*))::int) as " "
from in_zone z join zones g on g.zone_id = z.zone_id and g.zone_type = 'SCHOOL'
     join vehicles v on v.vehicle_id = z.vehicle_id
group by 1 order by 1;
\timing off

\echo '>>> [CITY] Which schools need a speed camera or a raised crossing first?'
select g.zone_name as school_zone,
       sum(case when t.speed_kmh > 33 then 1 else 0 end)                        as speeding_readings,
       count(distinct case when t.speed_kmh > 33 then t.vehicle_id end)          as distinct_vehicles,
       max(t.speed_kmh)                                                         as max_kmh,
       repeat('█', (sum(case when t.speed_kmh > 33 then 1 else 0 end) / 250)::int) as " "
from zone_hits h join zones g on g.zone_id = h.zone_id and g.zone_type = 'SCHOOL'
     join telemetry t on t.event_id = h.event_id
where hour(t.ts) between 7 and 16
group by 1 order by 2 desc limit 5;

\echo '>>> [CITY] Low-Emission Zone: how much diesel exhaust is released INSIDE the city center?'
select v.fleet_segment,
       count(distinct t.vehicle_id)                                  as vehicles_entering,
       (count(*) / 60.0)::int                                        as vehicle_hours_inside,
       sum(t.fuel_lph / 60.0)::int                                   as diesel_liters_inside,
       (sum(t.fuel_lph / 60.0) * 2.68 / 1000)::numeric(8,1)          as tailpipe_co2_tons,
       (sum(t.fuel_lph / 60.0) * 2.68 / 1000 * 365 / 45)::int        as co2_tons_per_year
from zone_hits h join telemetry t on t.event_id = h.event_id
     join vehicles v on v.vehicle_id = t.vehicle_id
where h.zone_id = 301
group by 1 order by 1;

\echo '>>> [OPS] Route adherence: is every vehicle on its assigned line?   Two-step pattern for IoT scale:'
\echo '>>>       1) planar GEOMETRY distance of ALL fixes to their LINESTRING (fast filter)  2) exact meters on the WGS-84 spheroid'
\echo '>>>       (GEOGRAPHY) for the suspects only.  Episodes are sessionized with CONDITIONAL_TRUE_EVENT (new episode after a 10 min gap).'
\timing on
with suspects as (
   select t.vehicle_id, t.ts, v.plate, v.drive_mode, r.line_no,
          ST_Distance(r.route_geog, STV_GeographyPoint(t.lon, t.lat)) as off_m
   from telemetry t join vehicles v on v.vehicle_id = t.vehicle_id join routes r on r.route_id = v.route_id
   where ST_Distance(r.route_geom, STV_GeometryPoint(t.lon, t.lat)) > 0.002          -- ~200 m, in degrees
), episodes as (
   select *, conditional_true_event(ts - lag(ts) > interval '10 minutes') over (partition by vehicle_id order by ts) as episode
   from suspects where off_m > 250
)
select plate, drive_mode, line_no as line, to_char(min(ts), 'YYYY-MM-DD HH24:MI') as left_route_at,
       datediff('minute', min(ts), max(ts)) + 1 as minutes_off_route, max(off_m)::int as max_deviation_m,
       'ALERT: unauthorized detour' as action
from episodes
group by plate, drive_mode, line_no, vehicle_id, episode
having count(*) >= 3
order by left_route_at;
\timing off

\echo '>>> [CITY] Harsh-braking black spots: GPS fixes binned with ST_GeoHash (~150 m cells), named by the nearest geofence.'
with cells as (
   select ST_GeoHash(STV_GeometryPoint(t.lon, t.lat) using parameters numchars = 7) as geohash,
          count(*) as harsh_brakes,
          sum(case when v.drive_mode = 'HUMAN' then 1 else 0 end) as by_humans,
          sum(case when v.drive_mode = 'AUTONOMOUS' then 1 else 0 end) as by_av,
          avg(t.lat) as lat, avg(t.lon) as lon
   from telemetry t join vehicles v on v.vehicle_id = t.vehicle_id
   where t.accel_ms2 <= -3.2
   group by 1
), ranked as (
   select * from cells order by harsh_brakes desc limit 8
)
select * from (
select c.geohash, c.lat::numeric(8,5) as lat, c.lon::numeric(8,5) as lon, c.harsh_brakes, c.by_humans, c.by_av,
       z.zone_name as nearest_landmark,
       ST_Distance(STV_GeographyPoint(c.lon, c.lat), STV_GeographyPoint(z.center_lon, z.center_lat))::int as meters_away,
       repeat('█', (c.harsh_brakes / 25)::int) as " "
from ranked c cross join zones z
where z.zone_type <> 'LOW_EMISSION'
limit 1 over (partition by c.geohash order by ST_Distance(STV_GeographyPoint(c.lon, c.lat), STV_GeographyPoint(z.center_lon, z.center_lat)))
) nearest order by harsh_brakes desc;

\echo '>>> [OEM] Where does the self-driving stack hand control back to the safety operator?  (disengagements by geofence)'
select nvl(g.zone_name, '(open road - everywhere else)') as location,
       sum(t.av_disengage)                                                  as disengagements,
       (sum(t.speed_kmh / 60.0))::int                                       as av_km_driven_there,
       (sum(t.speed_kmh / 60.0) / nullif(sum(t.av_disengage), 0))::int      as km_per_disengagement,
       repeat('█', (sum(t.av_disengage) / 25)::int) as " "
from telemetry t join vehicles v on v.vehicle_id = t.vehicle_id and v.drive_mode = 'AUTONOMOUS'
     left join (select h.event_id, z.zone_name from zone_hits h join zones z on z.zone_id = h.zone_id and z.zone_type = 'COMPLEX_JUNCTION') g
            on g.event_id = t.event_id
group by 1 order by 2 desc;
\echo '>>>       Three junctions = a sliver of the network, yet a large share of all disengagements: that is where to'
\echo '>>>       retrain perception / planning - and where the city should repaint lanes and retime signals.'

-- =====================================================================================
\! [ -n "$DEMO_PAUSE" ] && { echo; printf "%s" ">>> press ENTER for ACT 3 ... "; read x; } ; echo; tput rev 2>/dev/null; echo " ACT 3 | AUTONOMOUS vs. HUMAN DRIVERS - SAME LINES, SAME TIMETABLE, SAME WEATHER     "; tput sgr0 2>/dev/null
-- =====================================================================================
\echo '>>> First a KPI mart: one row per vehicle per day, straight from the raw events (energy integrated over the real'
\echo '>>> time between messages). It feeds the scorecards below AND is the feature store for the ML act.'
\timing on
create table vehicle_day as
with ev as (
   select t.*, r.speed_limit_kmh,
          least(datediff('second', lag(t.ts) over (partition by t.vehicle_id, t.ts::date order by t.ts), t.ts), 300) / 3600.0 as dt_h
   from telemetry t join vehicles v on v.vehicle_id = t.vehicle_id join routes r on r.route_id = v.route_id
)
select vehicle_id, ts::date as day,
       count(*)                                                       as events,
       max(odometer_km) - min(odometer_km)                            as km,
       sum(case when accel_ms2 <= -3.2 then 1 else 0 end)             as harsh_brakes,
       sum(case when accel_ms2 >=  2.6 then 1 else 0 end)             as harsh_accels,
       sum(abs_on)                                                    as abs_events,
       sum(case when speed_kmh > 0 then 1 else 0 end)                 as moving_events,
       sum(case when speed_kmh > speed_limit_kmh + 5 then 1 else 0 end) as speeding_events,
       stddev(case when speed_kmh > 0 and accel_ms2 between -3.19 and 2.59 then accel_ms2 end) as accel_std,
       sum(case when power_kw > 0 then power_kw * dt_h else 0 end)    as kwh_out,
       sum(case when power_kw < 0 then -power_kw * dt_h else 0 end)   as kwh_regen,
       sum(fuel_lph * dt_h)                                           as fuel_l,
       sum(case when speed_kmh = 0 then fuel_lph * dt_h else 0 end)   as idle_fuel_l,
       sum(passengers * speed_kmh * dt_h)                             as passenger_km,
       avg(passengers)                                                as avg_pax,
       avg(outside_temp_c)                                            as avg_out_temp,
       avg(wipers_on)                                                 as rain_share,
       min(energy_pct)                                                as min_energy_pct,
       avg(vibration_g)                                               as avg_vib,
       max(vibration_g)                                               as max_vib,
       avg(motor_temp_c)                                              as avg_motor_temp,
       max(motor_temp_c)                                              as max_motor_temp,
       avg(batt_temp_c)                                               as avg_batt_temp,
       avg(tire_psi)                                                  as avg_psi,
       min(tire_psi)                                                  as min_psi,
       sum(av_disengage)                                              as disengagements
from ev
group by 1, 2
order by 1, 2
segmented by hash(vehicle_id) all nodes;
\timing off
select to_char(count(*), '999,999') as vehicle_days, count(distinct vehicle_id) as vehicles, to_char(sum(km), '9,999,999') as total_km from vehicle_day;

\echo '>>> [OPS] [OEM] The safety scorecard.  Events per 100 km so that every segment is judged on equal terms.'
create table segment_scorecard as
select v.fleet_segment,
       count(distinct v.vehicle_id)                                                  as vehicles,
       sum(d.km)                                                                     as km,
       100 * sum(d.harsh_brakes) / sum(d.km)                                          as harsh_brakes_100km,
       100 * sum(d.harsh_accels) / sum(d.km)                                          as harsh_accels_100km,
       100.0 * sum(d.speeding_events) / sum(d.moving_events)                          as speeding_pct,
       avg(d.accel_std)                                                              as jerkiness,
       max(i.incidents)                                                              as incidents,
       100000 * max(i.incidents) / sum(d.km)                                          as incidents_100k_km,
       100000 * max(i.collisions) / sum(d.km)                                         as collisions_100k_km
from vehicle_day d join vehicles v using (vehicle_id)
     join (select v2.fleet_segment, count(*) as incidents, sum(case when severity <> 'NEAR_MISS' then 1 else 0 end) as collisions
           from incidents i2 join vehicles v2 using (vehicle_id) group by 1) i on i.fleet_segment = v.fleet_segment
group by 1
unsegmented all nodes;

select fleet_segment, vehicles, to_char(km, '9,999,999') as km_driven,
       harsh_brakes_100km::numeric(6,2) as "harsh brakes/100km",
       harsh_accels_100km::numeric(6,2) as "harsh accels/100km",
       speeding_pct::numeric(5,2)       as "speeding %",
       jerkiness::numeric(5,3)          as "jerkiness",
       incidents                        as "incidents",
       incidents_100k_km::numeric(6,2)  as "per 100k km",
       collisions_100k_km::numeric(6,2) as "collisions/100k km"
from segment_scorecard order by harsh_brakes_100km;

\echo '>>> Safety score 0-100 per vehicle (100 = flawless):  100 - 9 x harsh brakes/100km - 6 x harsh accels/100km - 2.5 x speeding%'
create table vehicle_score as
select v.vehicle_id, v.plate, v.fleet_segment, v.drive_mode, v.powertrain, v.operator_id, r.line_no,
       sum(d.km)                                         as km,
       100 * sum(d.harsh_brakes) / sum(d.km)              as hb_100km,
       100 * sum(d.harsh_accels) / sum(d.km)              as ha_100km,
       100.0 * sum(d.speeding_events) / sum(d.moving_events) as speeding_pct,
       avg(d.accel_std)                                  as jerkiness,
       sum(d.kwh_out - d.kwh_regen) / sum(d.km)           as kwh_km,
       100 * sum(d.fuel_l) / sum(d.km)                    as l_100km,
       greatest(0, 100 - 9 * 100 * sum(d.harsh_brakes) / sum(d.km) - 6 * 100 * sum(d.harsh_accels) / sum(d.km)
                       - 2.5 * 100.0 * sum(d.speeding_events) / sum(d.moving_events)) as safety_score
from vehicle_day d join vehicles v using (vehicle_id) join routes r using (route_id)
group by 1, 2, 3, 4, 5, 6, 7
unsegmented all nodes;

select fleet_segment, count(*) as vehicles,
       min(safety_score)::numeric(5,1) as worst, avg(safety_score)::numeric(5,1) as average, max(safety_score)::numeric(5,1) as best,
       stddev(safety_score)::numeric(5,1) as spread,
       repeat('█', (avg(safety_score) / 2.5)::int) as "average safety score"
from vehicle_score group by 1 order by 4 desc;
\echo '>>>       The AV stack is not only better on average - it is CONSISTENT: every autonomous bus drives like the best human.'

\echo '>>> [OPS] Driver coaching list: the 5 best and the 5 riskiest human drivers'
(select 'TOP 5'    as list, operator_id as driver, plate, line_no as line, hb_100km::numeric(5,2) as "harsh brakes /100km",
        speeding_pct::numeric(5,2) as "speeding %", safety_score::numeric(5,1) as score, repeat('█', (safety_score / 4)::int) as " "
 from vehicle_score where drive_mode = 'HUMAN' order by safety_score desc limit 5)
union all
(select 'BOTTOM 5', operator_id, plate, line_no, hb_100km::numeric(5,2), speeding_pct::numeric(5,2), safety_score::numeric(5,1), repeat('█', (safety_score / 4)::int)
 from vehicle_score where drive_mode = 'HUMAN' order by safety_score limit 5)
order by score desc;

\echo '>>> [OPS] Does bad weather change the picture?  Harsh brakes per 100 km, dry vs. rain:'
select v.drive_mode,
       (100 * sum(case when d.rain_share < 0.1 then d.harsh_brakes end) / sum(case when d.rain_share < 0.1 then d.km end))::numeric(5,2) as dry_days,
       (100 * sum(case when d.rain_share > 0.4 then d.harsh_brakes end) / sum(case when d.rain_share > 0.4 then d.km end))::numeric(5,2) as rainy_days,
       '+' || (100 * (sum(case when d.rain_share > 0.4 then d.harsh_brakes end) / sum(case when d.rain_share > 0.4 then d.km end))
                   / (sum(case when d.rain_share < 0.1 then d.harsh_brakes end) / sum(case when d.rain_share < 0.1 then d.km end)) - 100)::int || ' %' as rain_penalty
from vehicle_day d join vehicles v using (vehicle_id) group by 1 order by 1;

\echo '>>> [911] [OPS] Event-series PATTERN MATCHING (Vertica MATCH clause): the classic close-call signature'
\echo '>>>       "speeding for one or more readings, immediately followed by a harsh brake" - found across 13 million events:'
\timing on
select drive_mode, count(distinct vehicle_id) as vehicles_involved, count(distinct vehicle_id::varchar || '-' || mid::varchar) as close_call_patterns,
       max(speed_kmh) as max_speed_before_brake, min(accel_ms2) as hardest_brake_ms2
from (
   select t.vehicle_id, v.drive_mode, t.speed_kmh, t.accel_ms2, match_id() as mid
   from telemetry t join vehicles v on v.vehicle_id = t.vehicle_id join routes r on r.route_id = v.route_id
   match (partition by t.vehicle_id order by t.ts
          define speeding as t.speed_kmh > r.speed_limit_kmh + 5 and t.accel_ms2 > -3.2,
                 harsh    as t.accel_ms2 <= -3.2
          pattern p as (speeding+ harsh)
          rows match first event)
) m
group by 1 order by 1;
\timing off

-- =====================================================================================
\! [ -n "$DEMO_PAUSE" ] && { echo; printf "%s" ">>> press ENTER for ACT 4 ... "; read x; } ; echo; tput rev 2>/dev/null; echo " ACT 4 | ENERGY - SMOOTH DRIVING IS CHEAP DRIVING                                     "; tput sgr0 2>/dev/null
-- =====================================================================================
\echo '>>> [OPS] [OEM] Energy per km.  Assumptions: electricity 0.14 $/kWh, diesel 1.85 $/l, grid 0.45 kg CO2/kWh, diesel 2.68 kg CO2/l'
select v.fleet_segment,
       (nullif(sum(d.kwh_out - d.kwh_regen), 0) / sum(d.km))::numeric(5,3)        as "net kWh/km",
       (100 * sum(d.kwh_regen) / nullif(sum(d.kwh_out), 0))::numeric(4,1)          as "energy recovered by regen %",
       (100 * sum(d.fuel_l) / sum(d.km))::numeric(5,1)                             as "l/100km",
       (100 * nvl(sum(d.kwh_out - d.kwh_regen) * 0.14, 0) / sum(d.km) + 100 * nvl(sum(d.fuel_l) * 1.85, 0) / sum(d.km))::numeric(6,2) as "$ per 100 km",
       (nvl(sum(d.kwh_out - d.kwh_regen) * 0.45, 0) / sum(d.km) + nvl(sum(d.fuel_l) * 2.68, 0) / sum(d.km))::numeric(5,3)            as "kg CO2 per km",
       (1000 * (nvl(sum(d.kwh_out - d.kwh_regen) * 0.45, 0) + nvl(sum(d.fuel_l) * 2.68, 0)) / sum(d.passenger_km))::numeric(6,1)      as "g CO2 per passenger-km",
       repeat('█', ((100 * nvl(sum(d.kwh_out - d.kwh_regen) * 0.14, 0) / sum(d.km) + 100 * nvl(sum(d.fuel_l) * 1.85, 0) / sum(d.km)) / 3)::int) as "cost"
from vehicle_day d join vehicles v using (vehicle_id)
group by 1 order by 5;

\echo '>>> [OPS] Inside the human EV group: energy use by safety-score quartile - the coaching business case'
select 'Q' || q::varchar as safety_quartile, count(*) as drivers, min(safety_score)::int || ' - ' || max(safety_score)::int as score_range,
       avg(kwh_km)::numeric(5,3) as "kWh/km", avg(hb_100km)::numeric(5,2) as "harsh brakes /100km",
       repeat('█', (avg(kwh_km) * 25)::int) as " "
from (select *, ntile(4) over (order by safety_score desc) as q from vehicle_score where fleet_segment = 'Human EV') s
group by q order by q;

\echo '>>> [OEM] EV consumption and real-world range vs. ambient temperature (HVAC load) - WIDTH_BUCKET over vehicle-days.'
\echo '>>>       Measured on the autonomous buses only: their driving style is constant, so the temperature effect is isolated.'
select case b when 0 then 'below 5' when 7 then '35 and up' else (5 * b)::varchar || ' to ' || (5 * b + 5)::varchar end || ' C' as ambient,
       count(*) as vehicle_days,
       (sum(kwh_out - kwh_regen) / sum(km))::numeric(5,3)        as "kWh/km",
       (avg(bkwh) * 0.9 / (sum(kwh_out - kwh_regen) / sum(km)))::int as "usable range km",
       repeat('█', ((sum(kwh_out - kwh_regen) / sum(km)) * 25)::int) as " "
from (select d.*, v.battery_kwh as bkwh, width_bucket(d.avg_out_temp, 5, 35, 6) as b
      from vehicle_day d join vehicles v using (vehicle_id) where v.fleet_segment = 'Autonomous EV') x
group by b order by b;

\echo '>>> [OPS] Charging sessions detected from the state-of-charge signal (CONDITIONAL_TRUE_EVENT), range anxiety per segment:'
\timing on
with charge_cycles as (
   select vehicle_id, ts, energy_pct, odometer_km,
          conditional_true_event(energy_pct - lag(energy_pct) > 20) over (partition by vehicle_id order by ts) as cycle_no
   from telemetry
), per_cycle as (
   select vehicle_id, cycle_no, max(odometer_km) - min(odometer_km) as km, max(energy_pct) - min(energy_pct) as pct_used, min(energy_pct) as arrival_pct
   from charge_cycles group by 1, 2
)
select v.fleet_segment, count(*) as charge_cycles, avg(c.km)::int as avg_km_per_cycle,
       avg(c.pct_used)::numeric(4,1) as "avg % used", min(c.arrival_pct) as "lowest arrival %",
       sum(case when c.arrival_pct < 15 then 1 else 0 end) as "arrivals below 15%",
       (avg(c.km) / avg(c.pct_used) * 90)::int as "projected km on 90% of the pack"
from per_cycle c join vehicles v using (vehicle_id)
where v.powertrain = 'EV' and c.km > 50
group by 1 order by 1;
\timing off

\echo '>>> [OPS] [CITY] Diesel burned while standing still (stops, red lights, terminals) - an EV uses almost nothing there'
select to_char(sum(idle_fuel_l), '999,999')                                 as idle_liters_45_days,
       (100 * sum(idle_fuel_l) / sum(fuel_l))::numeric(4,1)                  as "% of all diesel",
       to_char(sum(idle_fuel_l) * 365 / 45 * 1.85, '$9,999,999')             as idle_cost_per_year,
       (sum(idle_fuel_l) * 365 / 45 * 2.68 / 1000)::int                      as idle_co2_tons_per_year
from vehicle_day d join vehicles v using (vehicle_id) where v.powertrain = 'DIESEL';

-- =====================================================================================
\! [ -n "$DEMO_PAUSE" ] && { echo; printf "%s" ">>> press ENTER for ACT 5 ... "; read x; } ; echo; tput rev 2>/dev/null; echo " ACT 5 | MACHINE LEARNING INSIDE THE DATABASE - THE DATA NEVER LEAVES VERTICA         "; tput sgr0 2>/dev/null
-- =====================================================================================
\echo '>>> 5.1 [OPS] Unsupervised: K-MEANS discovers driving styles.  The algorithm is NOT told which buses are autonomous.'
select normalize_fit('fleet_style_norm', 'vehicle_score', 'hb_100km,ha_100km,speeding_pct,jerkiness', 'zscore'
                     using parameters output_view = 'vehicle_style_norm');
\timing on
select kmeans('fleet_style_kmeans', 'vehicle_style_norm', 'hb_100km,ha_100km,speeding_pct,jerkiness', 3
              using parameters init_method = 'kmeanspp', max_iterations = 50, key_columns = 'vehicle_id');
\timing off
create table vehicle_style as
select vehicle_id, fleet_segment, drive_mode, safety_score, kwh_km,
       apply_kmeans(hb_100km, ha_100km, speeding_pct, jerkiness using parameters model_name = 'fleet_style_kmeans') as cluster_id
from vehicle_style_norm;

select case dense_rank() over (order by avg(s.safety_score) desc) when 1 then 'A  smooth' when 2 then 'B  average' else 'C  aggressive' end as discovered_style,
       count(*) as vehicles,
       sum(case when s.drive_mode = 'AUTONOMOUS' then 1 else 0 end) as "autonomous",
       sum(case when s.drive_mode = 'HUMAN' then 1 else 0 end)      as "human",
       avg(c.hb_100km)::numeric(5,2) as "harsh brakes/100km", avg(c.speeding_pct)::numeric(5,2) as "speeding %",
       avg(c.jerkiness)::numeric(5,3) as jerkiness, avg(s.safety_score)::numeric(5,1) as safety_score,
       repeat('█', (count(*) / 5)::int) as " "
from vehicle_style s join vehicle_score c using (vehicle_id)
group by s.cluster_id order by safety_score desc;
\echo '>>>     Every autonomous bus lands in the smooth cluster - next to the best human drivers. Cluster C is the coaching list.'

\echo ''
\echo '>>> 5.2 [OPS] [OEM] Supervised: PREDICTIVE MAINTENANCE.  Will this vehicle break down within the next 7 days?'
\echo '>>>     Feature store = the vehicle-day mart + SQL window functions: each sensor vs. the SAME vehicle 4-14 days earlier.'
create table pdm_features as
select d.vehicle_id * 1000 + (d.day - '2020-01-01'::date) % 1000 as row_id,
       d.vehicle_id, d.day, v.powertrain, v.fleet_segment,
       d.avg_vib, d.max_vib, d.avg_motor_temp, d.max_motor_temp, d.avg_psi, d.min_psi, d.avg_out_temp,
       d.avg_vib - avg(d.avg_vib) over (partition by d.vehicle_id order by d.day rows between 14 preceding and 4 preceding) as vib_vs_baseline,
       (d.avg_motor_temp - 0.4 * d.avg_out_temp)
           - avg(d.avg_motor_temp - 0.4 * d.avg_out_temp) over (partition by d.vehicle_id order by d.day rows between 14 preceding and 4 preceding) as temp_vs_baseline,
       d.avg_psi - avg(d.avg_psi) over (partition by d.vehicle_id order by d.day rows between 14 preceding and 4 preceding) as psi_vs_baseline,
       d.avg_vib        - lag(d.avg_vib, 2)        over (partition by d.vehicle_id order by d.day) as vib_trend_2d,
       d.avg_motor_temp - lag(d.avg_motor_temp, 2) over (partition by d.vehicle_id order by d.day) as temp_trend_2d,
       d.avg_psi        - lag(d.avg_psi, 2)        over (partition by d.vehicle_id order by d.day) as psi_trend_2d,
       100 * d.harsh_brakes / nullif(d.km, 0)                                                     as hb_100km,
       count(*) over (partition by d.vehicle_id order by d.day rows between 14 preceding and 4 preceding) as history_days,
       case when m.event_ts::date between d.day and d.day + 7 then 1 else 0 end                   as fails_within_7d,
       case when abs(hash(d.vehicle_id)) % 10 < 7 then 'TRAIN' else 'TEST' end                   as split
from vehicle_day d join vehicles v using (vehicle_id)
     left join maintenance_log m on m.vehicle_id = d.vehicle_id and m.event_type = 'BREAKDOWN'
order by vehicle_id, day
segmented by hash(vehicle_id) all nodes;

\echo '>>>     Train only on days whose 7-day outcome is already known; hold out 30% of the VEHICLES (not rows) for an honest test.'
create or replace view pdm_train as select * from pdm_features where history_days >= 5 and split = 'TRAIN' and day <= (select max(day) - 7 from vehicle_day);
create or replace view pdm_test  as select * from pdm_features where history_days >= 5 and split = 'TEST'  and day <= (select max(day) - 7 from vehicle_day);
create or replace view pdm_today as select * from pdm_features where day = (select max(day) from vehicle_day);
select 'train' as dataset, count(*) as vehicle_days, count(distinct vehicle_id) as vehicles, sum(fails_within_7d) as "positives (fails within 7d)" from pdm_train
union all select 'test', count(*), count(distinct vehicle_id), sum(fails_within_7d) from pdm_test order by 1 desc;

\timing on
select rf_classifier('fleet_pdm_rf', 'pdm_train', 'fails_within_7d',
                     'vib_vs_baseline,temp_vs_baseline,psi_vs_baseline,vib_trend_2d,temp_trend_2d,psi_trend_2d,max_vib,max_motor_temp,min_psi,hb_100km,avg_out_temp'
                     using parameters ntree = 80, max_depth = 8, max_breadth = 256, sampling_size = 0.8, seed = 42, id_column = 'row_id');
\timing off

create table pdm_test_scored as
select vehicle_id, day, fails_within_7d as obs,
       predict_rf_classifier(vib_vs_baseline, temp_vs_baseline, psi_vs_baseline, vib_trend_2d, temp_trend_2d, psi_trend_2d, max_vib, max_motor_temp, min_psi, hb_100km, avg_out_temp
                             using parameters model_name = 'fleet_pdm_rf', type = 'probability', class = '1')::float as prob
from pdm_test;

\echo '>>>     Model quality on vehicles it has never seen (ROC function):'
select decision_boundary as threshold, false_positive_rate::numeric(6,4) as false_positive_rate, true_positive_rate::numeric(6,4) as "recall (true positive rate)",
       auc::numeric(6,4) as "AUC", repeat('█', (true_positive_rate * 40)::int) as "recall"
from (select roc(obs, prob using parameters num_bins = 100) over () from pdm_test_scored) r
where decision_boundary > 0 and round(decision_boundary * 100)::int % 10 = 0 order by 1;

\echo '>>>     Confusion matrix at the alert threshold 0.40:'
select sum(case when obs = 1 and prob >= 0.4 then 1 else 0 end) as "caught (TP)",
       sum(case when obs = 1 and prob <  0.4 then 1 else 0 end) as "missed (FN)",
       sum(case when obs = 0 and prob >= 0.4 then 1 else 0 end) as "false alarm (FP)",
       sum(case when obs = 0 and prob <  0.4 then 1 else 0 end) as "quiet and healthy (TN)",
       (100.0 * sum(case when obs = 1 and prob >= 0.4 then 1 else 0 end) / nullif(sum(case when prob >= 0.4 then 1 else 0 end), 0))::numeric(5,1) as "precision %",
       (100.0 * sum(case when obs = 1 and prob >= 0.4 then 1 else 0 end) / sum(obs))::numeric(5,1) as "recall %"
from pdm_test_scored;

\echo '>>>     The operational view - per BREAKDOWN in the test fleet: was there an alert before it happened, and how early?'
select m.component, count(*) as breakdowns,
       sum(case when a.first_alert is not null then 1 else 0 end) as "alerted in advance",
       avg(datediff('day', a.first_alert, m.event_ts::date))::numeric(3,1) as avg_days_of_warning
from maintenance_log m
     join (select vehicle_id, min(day) as first_day, max(day) as last_day from pdm_test_scored group by 1) t
          on t.vehicle_id = m.vehicle_id and m.event_ts::date between t.first_day + 3 and t.last_day + 7
     left join (select vehicle_id, min(day) as first_alert from pdm_test_scored where prob >= 0.4 and obs = 1 group by 1) a on a.vehicle_id = m.vehicle_id
where m.event_type = 'BREAKDOWN'
group by 1 order by 1;
\echo '>>>     Wear-type faults announce themselves days ahead; sudden ELECTRICAL faults carry no precursor in these sensors - an honest limit.'

\echo '>>>     What did the forest learn?  (RF_PREDICTOR_IMPORTANCE)'
select predictor_name, importance_value::numeric(6,4) as importance, repeat('█', (importance_value * 100)::int) as " "
from (select rf_predictor_importance(using parameters model_name = 'fleet_pdm_rf')) i
order by importance_value desc;

\echo '>>> 5.3 [OPS] Score TODAY and turn it into work orders - which bus, which component, which depot, how far away.'
\echo '>>>     (+/- columns = todays sensor level minus the same vehicle 4-14 days ago)'
create table pdm_work_orders as
select t.vehicle_id,
       predict_rf_classifier(vib_vs_baseline, temp_vs_baseline, psi_vs_baseline, vib_trend_2d, temp_trend_2d, psi_trend_2d, max_vib, max_motor_temp, min_psi, hb_100km, avg_out_temp
                             using parameters model_name = 'fleet_pdm_rf', type = 'probability', class = '1')::float as risk,
       case when psi_vs_baseline < -2.5 then 'TIRE: slow leak'
            when vib_vs_baseline > 0.035 then 'DRIVETRAIN: bearing wear'
            when temp_vs_baseline > 2.5 then 'COOLING: overheating' else 'GENERAL INSPECTION' end as suspected_fault,
       vib_vs_baseline, temp_vs_baseline, psi_vs_baseline
from pdm_today t;

select v.plate, v.fleet_segment, r.line_no as line, (100 * w.risk)::int as "risk %", w.suspected_fault,
       w.vib_vs_baseline::numeric(5,3) as "vib +/- g", w.temp_vs_baseline::numeric(4,1) as "temp +/- C", w.psi_vs_baseline::numeric(4,1) as "psi +/-",
       f.facility_name as depot,
       (ST_Distance(STV_GeographyPoint(l.lon, l.lat), f.geog) / 1000)::numeric(4,1) as "km to depot",
       repeat('█', (10 * w.risk)::int) as risk
from pdm_work_orders w join vehicles v using (vehicle_id) join routes r using (route_id)
     join facilities f on f.facility_id = v.depot_id
     join (select vehicle_id, lat, lon from telemetry limit 1 over (partition by vehicle_id order by ts desc)) l using (vehicle_id)
where w.risk >= 0.4
order by w.risk desc, v.plate;

\echo '>>>     Reality check against the hidden failure schedule of the simulator (the model has never seen it):'
select case when w.risk >= 0.4 and p.vehicle_id is not null then '1. flagged - and it really is about to fail'
            when w.risk >= 0.4                               then '2. flagged - no failure planned (false alarm)'
            when p.component = 'ELECTRICAL'                  then '4. missed  - sudden electrical fault, no precursor in any sensor'
            else                                                  '3. missed' end as outcome,
       v.plate, (100 * w.risk)::int as "risk %",
       nvl(lower(p.component), '-')                                        as hidden_fault,
       nvl('in ' || (p.fail_day_idx - d.last_idx)::varchar || ' days', '-') as breaks_down
from pdm_work_orders w join vehicles v using (vehicle_id)
     cross join (select max(day_idx) as last_idx from weather_hourly) d
     left join sim_failure_plan p on p.vehicle_id = w.vehicle_id and p.fail_day_idx between d.last_idx + 1 and d.last_idx + 7
where w.risk >= 0.4 or p.vehicle_id is not null
order by 1, 3 desc;

\echo '>>>     The business case: an unplanned breakdown = repair + towing (1,200 $) + 36 h of lost service (95 $/h); a planned fix ~ 40% of the repair.'
\echo '>>>     Avoidable = wear-type faults only (no ELECTRICAL), and only 80% of those - in line with the advance-alert rate measured above.'
select count(*)                                                                        as breakdowns_in_45_days,
       to_char(avg(cost_usd + 1200 + downtime_hours * 95), '$999,999')                  as avg_cost_unplanned,
       to_char(avg(cost_usd * 0.4), '$999,999')                                         as avg_cost_planned,
       to_char(sum(cost_usd + 1200 + downtime_hours * 95) * 365 / 45, '$99,999,999')    as breakdown_cost_per_year,
       to_char(0.8 * sum(case when component <> 'ELECTRICAL' then cost_usd * 0.6 + 1200 + downtime_hours * 95 end) * 365 / 45, '$99,999,999') as avoidable_per_year
from maintenance_log where event_type = 'BREAKDOWN';

\echo ''
\echo '>>> 5.4 [OPS] [OEM] Unsupervised anomaly detection: ISOLATION FOREST - the unknown unknowns, no labels needed'
create view iforest_input as
select f.row_id, f.vehicle_id, f.day, f.vib_vs_baseline, f.temp_vs_baseline, f.psi_vs_baseline, f.hb_100km, d.min_energy_pct, d.km
from pdm_features f join vehicle_day d on d.vehicle_id = f.vehicle_id and d.day = f.day where f.history_days >= 5;
\timing on
select iforest('fleet_iforest', 'iforest_input', 'vib_vs_baseline,temp_vs_baseline,psi_vs_baseline,hb_100km,min_energy_pct,km'
               using parameters ntree = 100, sampling_size = 0.3, seed = 7, id_column = 'row_id');
\timing off
select v.plate, v.fleet_segment, s.day, s.score::numeric(5,3) as anomaly_score,
       case when s.km < 150 then 'short day: ' || s.km::int || ' km (breakdown / out of service?)'
            when s.psi_vs_baseline < -3 then 'tire pressure ' || s.psi_vs_baseline::numeric(4,1) || ' psi below its own baseline'
            when s.vib_vs_baseline > 0.05 then 'vibration +' || s.vib_vs_baseline::numeric(4,3) || ' g above baseline'
            when s.temp_vs_baseline > 4 then 'motor temperature +' || s.temp_vs_baseline::numeric(4,1) || ' C above baseline'
            when s.min_energy_pct < 10 then 'arrived with only ' || s.min_energy_pct || ' % energy'
            when s.hb_100km > 6 then s.hb_100km::numeric(4,1) || ' harsh brakes per 100 km'
            else 'unusual combination of readings' end as why_is_it_odd
from (select vehicle_id, day, km, psi_vs_baseline, vib_vs_baseline, temp_vs_baseline, min_energy_pct, hb_100km,
             (apply_iforest(vib_vs_baseline, temp_vs_baseline, psi_vs_baseline, hb_100km, min_energy_pct, km
                            using parameters model_name = 'fleet_iforest')).anomaly_score as score
      from iforest_input where day >= (select max(day) - 2 from vehicle_day)) s
     join vehicles v using (vehicle_id)
order by s.score desc limit 10;

\echo ''
\echo '>>> 5.5 [OEM] [OPS] Explainable model: LINEAR REGRESSION of energy use (kWh/km) per EV per day - what really drives consumption?'
create view energy_model_input as
select d.vehicle_id, d.day, (d.kwh_out - d.kwh_regen) / d.km as kwh_km,
       d.accel_std                         as jerkiness,
       100 * d.harsh_brakes / d.km         as hb_100km,
       abs(d.avg_out_temp - 21)            as degrees_from_21c,
       d.avg_pax                           as avg_passengers,
       case when r.service_type = 'EXPRESS' then 1 else 0 end as is_express,
       case when v.drive_mode = 'AUTONOMOUS' then 1 else 0 end as is_autonomous
from vehicle_day d join vehicles v using (vehicle_id) join routes r using (route_id)
where v.powertrain = 'EV' and d.km > 150;
select linear_reg('fleet_energy_lr', 'energy_model_input', 'kwh_km', 'jerkiness,hb_100km,degrees_from_21c,avg_passengers,is_express,is_autonomous');
select predictor, coefficient::numeric(8,4) as "kWh/km per unit", std_err::numeric(8,4) as std_err, t_value::numeric(8,1) as t_value,
       case when p_value < 0.001 then '***' when p_value < 0.01 then '**' when p_value < 0.05 then '*' else 'not significant' end as significance
from (select get_model_attribute(using parameters model_name = 'fleet_energy_lr', attr_name = 'details')) a;
select rsq::numeric(5,3) as r_squared, comment
from (select rsquared(obs, pred) over () from
        (select kwh_km as obs, predict_linear_reg(jerkiness, hb_100km, degrees_from_21c, avg_passengers, is_express, is_autonomous
                                                  using parameters model_name = 'fleet_energy_lr') as pred from energy_model_input) p) r;
\echo '>>>     Read it like this: smoothness (jerkiness) is the big lever.  Once driving style is in the model, the "is_autonomous" flag adds'
\echo '>>>     little - the AV advantage IS its smoothness, which means human drivers can be coached towards it.'

\echo ''
\echo '>>>     Every model is a first-class database object - versionable, securable, exportable (PMML / TensorFlow import-export):'
select model_name, model_type, to_char(create_time, 'YYYY-MM-DD HH24:MI') as created, (size / 1024)::int as size_kb
from models where schema_name = 'FLEET' order by create_time;

-- =====================================================================================
\! [ -n "$DEMO_PAUSE" ] && { echo; printf "%s" ">>> press ENTER for ACT 6 ... "; read x; } ; echo; tput rev 2>/dev/null; echo " ACT 6 | EMERGENCY RESPONSE - SECONDS MATTER                                          "; tput sgr0 2>/dev/null
-- =====================================================================================
\echo '>>> [911] Scenario: 17:42 on the last day - multi-vehicle collision on Ibn Gabirol St. near Rabin Square (34.7812 E, 32.0815 N).'
create table scenario as
select (select max(ts)::date + interval '17:42' from telemetry)  as incident_ts,
       34.7812::float as lon, 32.0815::float as lat,
       STV_GeographyPoint(34.7812, 32.0815)                      as incident_geog,
       ST_Buffer(STV_GeometryPoint(34.7812, 32.0815), 0.0035)    as closure_geom        -- ~350 m road closure
unsegmented all nodes;

\echo '>>> 1) Closest trauma centers (ST_Distance on the spheroid):'
select f.facility_name as hospital, (ST_Distance(f.geog, s.incident_geog) / 1000)::numeric(5,2) as km_away,
       ceil(ST_Distance(f.geog, s.incident_geog) / 1000 * 1.4 / 40 * 60)::int as "eta min (40 km/h, detour factor 1.4)"
from facilities f cross join scenario s where f.facility_type = 'HOSPITAL' order by 2;

\echo '>>> 2) Fleet vehicles within 400 m at 17:42 (STV_DWithin) - rolling cameras and sensors that are already on scene:'
create table scenario_positions as
select t.vehicle_id, t.ts, t.lat, t.lon, t.speed_kmh, t.passengers
from telemetry t cross join scenario s
where t.ts between s.incident_ts - interval '3 minutes' and s.incident_ts
limit 1 over (partition by t.vehicle_id order by t.ts desc);

select v.plate, v.drive_mode, r.line_no as line, to_char(p.ts, 'HH24:MI:SS') as last_fix, p.passengers as pax,
       ST_Distance(STV_GeographyPoint(p.lon, p.lat), s.incident_geog)::int as meters_from_incident,
       case when v.drive_mode = 'AUTONOMOUS' then 'stream 360 camera + lidar to dispatch; hold position' else 'radio driver; hold at next stop' end as action
from scenario_positions p cross join scenario s join vehicles v using (vehicle_id) join routes r using (route_id)
where STV_DWithin(STV_GeographyPoint(p.lon, p.lat), s.incident_geog, 400)
order by 6 limit 8;

\echo '>>> 3) Green corridor: the ambulance drives Ichilov -> incident.  Which buses are within 200 m of that path right now?'
select v.drive_mode, count(*) as vehicles_in_corridor, sum(p.passengers) as passengers_on_board,
       case when v.drive_mode = 'AUTONOMOUS' then 'V2X command: pull over and yield - executed in seconds, confirmed by telemetry'
            else 'voice radio to each driver - depends on human reaction' end as how_the_corridor_is_cleared
from scenario_positions p join vehicles v using (vehicle_id)
     cross join (select ST_GeographyFromText('LINESTRING(34.7895 32.0803, 34.7850 32.0808, 34.7812 32.0815)') as corridor) c
where STV_DWithin(c.corridor, STV_GeographyPoint(p.lon, p.lat), 200)
group by 1 order by 1;

\echo '>>> 4) [CITY] Which bus lines cross the closure and must be diverted?  (ST_Intersects: LINESTRING x buffered POINT)'
select r.line_no as line, r.route_name,
       (ST_Length(ST_Intersection(r.route_geom, s.closure_geom)) * 111)::numeric(4,2) as km_inside_closure,
       count(p.vehicle_id) as buses_on_the_line_now, sum(p.passengers) as passengers_affected
from routes r cross join scenario s
     left join vehicles v on v.route_id = r.route_id
     left join scenario_positions p on p.vehicle_id = v.vehicle_id
where ST_Intersects(r.route_geom, s.closure_geom)
group by 1, 2, 3 order by 5 desc;

-- =====================================================================================
\! [ -n "$DEMO_PAUSE" ] && { echo; printf "%s" ">>> press ENTER for ACT 7 ... "; read x; } ; echo; tput rev 2>/dev/null; echo " ACT 7 | EXECUTIVE SUMMARY                                                            "; tput sgr0 2>/dev/null
-- =====================================================================================
create table exec_kpi as
select v.fleet_segment,
       sum(d.km) as km,
       max(c.harsh_brakes_100km) as hb, max(c.speeding_pct) as speeding, max(c.incidents_100k_km) as inc, max(c.collisions_100k_km) as coll,
       avg(s.safety_score) as score,
       nullif(sum(d.kwh_out - d.kwh_regen), 0) / sum(d.km) as kwh_km, 100 * sum(d.fuel_l) / sum(d.km) as l_100km,
       100 * (nvl(sum(d.kwh_out - d.kwh_regen), 0) * 0.14 + nvl(sum(d.fuel_l), 0) * 1.85) / sum(d.km) as usd_100km,
       (nvl(sum(d.kwh_out - d.kwh_regen), 0) * 0.45 + nvl(sum(d.fuel_l), 0) * 2.68) / sum(d.km) as co2_kg_km,
       max(b.breakdowns) as breakdowns
from vehicle_day d join vehicles v using (vehicle_id)
     join segment_scorecard c using (fleet_segment)
     join (select fleet_segment, avg(safety_score) as safety_score from vehicle_score group by 1) s using (fleet_segment)
     left join (select v2.fleet_segment, count(*) as breakdowns from maintenance_log m join vehicles v2 using (vehicle_id) where m.event_type = 'BREAKDOWN' group by 1) b using (fleet_segment)
group by 1
unsegmented all nodes;

\echo '>>> 45 days, same lines, same timetable, same weather:'
select kpi,
       max(case when fleet_segment = 'Autonomous EV' then val end) as "Autonomous EV",
       max(case when fleet_segment = 'Human EV'      then val end) as "Human EV",
       max(case when fleet_segment = 'Human Diesel'  then val end) as "Human Diesel"
from (          select 1 as ord, 'Safety score (0-100)' as kpi, fleet_segment, to_char(score, '990.0') as val from exec_kpi
      union all select 2, 'Harsh brakes per 100 km',        fleet_segment, to_char(hb, '990.00')        from exec_kpi
      union all select 3, 'Time above speed limit (%)',     fleet_segment, to_char(speeding, '990.00')  from exec_kpi
      union all select 4, 'Incidents per 100,000 km',       fleet_segment, to_char(inc, '990.00')       from exec_kpi
      union all select 5, 'Collisions per 100,000 km',      fleet_segment, to_char(coll, '990.00')      from exec_kpi
      union all select 6, 'Energy: kWh per km',             fleet_segment, nvl(to_char(kwh_km, '990.000'), '      -') from exec_kpi
      union all select 7, 'Energy: liters per 100 km',      fleet_segment, nvl(to_char(l_100km, '990.0'), '      -')  from exec_kpi
      union all select 8, 'Energy cost, $ per 100 km',      fleet_segment, to_char(usd_100km, '990.00') from exec_kpi
      union all select 9, 'CO2, kg per km',                 fleet_segment, to_char(co2_kg_km, '990.000') from exec_kpi
      union all select 10, 'Unplanned breakdowns per 100 vehicles', e.fleet_segment, to_char(100.0 * e.breakdowns / c.n, '990.0')
                from exec_kpi e join (select fleet_segment, count(*) as n from vehicles group by 1) c on c.fleet_segment = e.fleet_segment) k
group by ord, kpi order by ord;

\echo '>>> What is it worth?  Annualized value if the human-driven segments performed like the autonomous EV segment'
\echo '>>> (collision = 18,500 $ average claim; breakdown savings come from the predictive-maintenance model, fleet-wide):'
select h.fleet_segment as "segment upgraded to AV-EV level",
       to_char(h.km * 365 / 45, '99,999,999')                                                        as km_per_year,
       to_char((h.usd_100km - a.usd_100km) * h.km / 100 * 365 / 45, '$99,999,999')                    as energy_saving,
       ((h.coll - a.coll) * h.km / 100000 * 365 / 45)::int                                           as collisions_avoided,
       to_char((h.coll - a.coll) * h.km / 100000 * 365 / 45 * 18500, '$99,999,999')                   as collision_cost_avoided,
       to_char((h.co2_kg_km - a.co2_kg_km) * h.km * 365 / 45 / 1000, '999,999')                       as co2_tons_avoided
from exec_kpi h cross join (select * from exec_kpi where fleet_segment = 'Autonomous EV') a
where h.fleet_segment <> 'Autonomous EV'
order by 1;

\echo ''
\echo '>>> One platform did all of it: IoT-scale load, time series, geospatial, pattern matching and machine learning -'
\echo '>>> in SQL, in place, in seconds.   Next: open the VerticaPy notebook for the visual story (03_smart_fleet_verticapy.ipynb).'
\! echo; tput rev 2>/dev/null; echo " End of part 2 "; tput sgr0 2>/dev/null
