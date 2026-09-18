--
-- =====================================================================================
--  VERTICA SMART FLEET DEMO  -  part 1 of 3 : schema, geospatial reference data, IoT load
-- =====================================================================================
--  Autonomous vs. human-driven city buses: geospatial analytics + in-database ML
--
--  Run on the Vertica host:     /opt/vertica/bin/vsql -f 01_smart_fleet_setup.sql
--  then:                        /opt/vertica/bin/vsql -f 02_smart_fleet_analytics.sql
--  (no vsql on your laptop?     python run_demo.py 01_smart_fleet_setup.sql)
--
--  Everything is generated INSIDE Vertica with plain SQL - no files to copy, no ETL tool.
--  The data is SYNTHETIC. It comes from a small physics simulator (stop-to-stop bus
--  kinematics, traction/regeneration energy model, component-wear signatures), so the
--  numbers behave like a real fleet, but they are an illustration, not a field study.
--  This is a demo - it is not intended to run in production.
--
--  Scale knobs (320 vehicles x 45 days x 1 sample/min  =  ~13.4 million IoT events):
\set DEMO_DAYS   45
\set FLEET_SIZE  320
\set SAMPLE_SEC  60
--

\! tput rev 2>/dev/null; echo " VERTICA SMART FLEET DEMO | part 1: build the digital twin of a city bus fleet "; tput sgr0 2>/dev/null
\echo '   Tel Aviv metropolitan area - 12 bus lines - autonomous (L4) e-buses, human-driven e-buses, human-driven diesel'
\echo ''
select version() as vertica_version;

drop schema if exists FLEET cascade;
create schema FLEET;
set search_path to FLEET, public;

-- helper: a numbers table 0..99999 (built with Vertica's TIMESERIES gap-filling clause)
create table numbers (n int not null) order by n unsegmented all nodes;
insert into numbers
select datediff('second', '2000-01-01 00:00:00'::timestamp, slice) as n
from (select '2000-01-01 00:00:00'::timestamp as t union all select '2000-01-02 03:46:39'::timestamp) a
timeseries slice as '1 second' over (order by t);
commit;

-- =====================================================================================
\! echo; tput rev 2>/dev/null; echo " 1.1  Bus lines as real GEOMETRY / GEOGRAPHY objects (WKT LINESTRINGs)            "; tput sgr0 2>/dev/null
-- =====================================================================================
create table routes (
   route_id         int          not null primary key,
   line_no          varchar(8)   not null,
   route_name       varchar(80)  not null,
   service_type     varchar(12)  not null,      -- URBAN | EXPRESS
   stop_spacing_m   int          not null,      -- average distance between stops
   speed_limit_kmh  int          not null,
   route_geom       geometry(4000),             -- planar lon/lat : fast point-in-polygon, distance-to-line
   route_geog       geography(4000),            -- spheroid       : true lengths / distances in meters
   length_km        numeric(7,2)
) order by route_id unsegmented all nodes;

insert into routes (route_id, line_no, route_name, service_type, stop_spacing_m, speed_limit_kmh, route_geom)
select id, line_no, name, stype, spacing, lim, ST_GeomFromText(wkt) from (
          select  1 id, '1'   line_no, 'Coastal: Jaffa - Port - University'          name, 'URBAN'   stype, 430 spacing, 50 lim, 'LINESTRING(34.7565 32.0550, 34.7655 32.0700, 34.7705 32.0800, 34.7745 32.0930, 34.7765 32.0975, 34.7850 32.1020, 34.7960 32.1120, 34.8044 32.1133)' wkt
union all select  2, '4',   'Allenby - Dizengoff - Port',                  'URBAN',   400, 50, 'LINESTRING(34.7800 32.0565, 34.7720 32.0640, 34.7715 32.0690, 34.7745 32.0755, 34.7740 32.0779, 34.7760 32.0870, 34.7775 32.0935, 34.7765 32.0975)'
union all select  3, '5',   'Rothschild - Ibn Gabirol - Savidor',          'URBAN',   400, 50, 'LINESTRING(34.7800 32.0565, 34.7705 32.0630, 34.7790 32.0727, 34.7806 32.0809, 34.7820 32.0868, 34.7982 32.0837)'
union all select  4, '10',  'Crosstown: Jaffa - Azrieli - Petah Tikva',    'URBAN',   480, 50, 'LINESTRING(34.7565 32.0550, 34.7700 32.0560, 34.7850 32.0540, 34.7920 32.0745, 34.8020 32.0838, 34.8130 32.0840, 34.8352 32.0900, 34.8650 32.0900, 34.8875 32.0871)'
union all select  5, '18',  'Bat Yam - Jaffa - City Center - Savidor',     'URBAN',   450, 50, 'LINESTRING(34.7500 32.0171, 34.7520 32.0300, 34.7600 32.0450, 34.7590 32.0545, 34.7720 32.0640, 34.7745 32.0720, 34.7806 32.0809, 34.7982 32.0837)'
union all select  6, '25',  'Holon - Azrieli - Ichilov - University',      'URBAN',   470, 50, 'LINESTRING(34.7790 32.0160, 34.7800 32.0350, 34.7800 32.0565, 34.7920 32.0745, 34.7895 32.0803, 34.7930 32.0900, 34.7960 32.1020, 34.8044 32.1133)'
union all select  7, '40',  'Airport Express: Savidor - Ben Gurion T3',    'EXPRESS', 600, 70, 'LINESTRING(34.7982 32.0837, 34.7920 32.0745, 34.7850 32.0540, 34.8250 32.0330, 34.8530 32.0290, 34.8708 32.0005)'
union all select  8, '60',  'Hospital Link: Ichilov - Sheba - Kiryat Ono', 'URBAN',   460, 50, 'LINESTRING(34.7895 32.0803, 34.7920 32.0745, 34.8100 32.0710, 34.8230 32.0560, 34.8440 32.0457, 34.8570 32.0610)'
union all select  9, '90',  'North Express: Savidor - Glilot - Herzliya',  'EXPRESS', 600, 70, 'LINESTRING(34.7982 32.0837, 34.7960 32.1020, 34.8070 32.1390, 34.8080 32.1620, 34.8447 32.1624)'
union all select 10, '66',  'Ramat Gan - Givatayim - Bar Ilan - Bnei Brak','URBAN',   420, 50, 'LINESTRING(34.8020 32.0838, 34.8100 32.0710, 34.8250 32.0480, 34.8430 32.0690, 34.8352 32.0849)'
union all select 11, '72',  'South Ring: Wolfson - Holon - Azor - Sheba',  'URBAN',   480, 50, 'LINESTRING(34.7610 32.0365, 34.7500 32.0230, 34.7790 32.0160, 34.8060 32.0240, 34.8250 32.0330, 34.8440 32.0457)'
union all select 12, '100', 'Innovation Shuttle: University - Atidim - BBC','URBAN',  440, 50, 'LINESTRING(34.8044 32.1133, 34.8230 32.1160, 34.8420 32.1140, 34.8380 32.1090, 34.8300 32.1010, 34.8250 32.0950)'
) r;

-- same shape as a GEOGRAPHY (WGS-84 spheroid) -> ST_Length returns true meters
update routes set route_geog = ST_GeographyFromText(ST_AsText(route_geom));
update routes set length_km  = (ST_Length(route_geog) / 1000)::numeric(7,2);
commit;

select line_no as line, route_name, service_type, ST_NumPoints(route_geom) as waypoints,
       length_km as "ST_Length (km)", repeat('█', (length_km / 1.5)::int) as " "
from routes order by route_id;

-- Densify every line into one post per 50 m.  ST_PointN walks the LINESTRING vertices, DISTANCEV (Vincenty)
-- measures each segment in meters, and the numbers table interpolates the 50 m posts.
create table route_posts (route_id int not null, idx int not null, lon float not null, lat float not null)
order by route_id, idx unsegmented all nodes;

insert into route_posts
with vertices as (
   select r.route_id, n.n as seq, ST_X(ST_PointN(r.route_geom, n.n)) as lon, ST_Y(ST_PointN(r.route_geom, n.n)) as lat
   from routes r join numbers n on n.n between 1 and ST_NumPoints(r.route_geom)
), segments as (
   select route_id, seq, lon, lat,
          lead(lon) over w as lon2, lead(lat) over w as lat2,
          DISTANCEV(lat, lon, lead(lat) over w, lead(lon) over w) * 1000 as seg_m
   from vertices window w as (partition by route_id order by seq)
), chained as (
   select *, nvl(sum(seg_m) over (partition by route_id order by seq rows between unbounded preceding and 1 preceding), 0) as start_m
   from segments where lon2 is not null
)
select c.route_id, n.n,
       c.lon + (c.lon2 - c.lon) * (n.n * 50 - c.start_m) / c.seg_m,
       c.lat + (c.lat2 - c.lat) * (n.n * 50 - c.start_m) / c.seg_m
from chained c join numbers n on n.n * 50 >= c.start_m and n.n * 50 < c.start_m + c.seg_m and n.n < 2000;
commit;

-- =====================================================================================
\! echo; tput rev 2>/dev/null; echo " 1.2  Geofences: school zones, hospital quiet zones, low-emission zone, depots     "; tput sgr0 2>/dev/null
-- =====================================================================================
create table zones (
   zone_id          int          not null primary key,
   zone_name        varchar(80)  not null,
   zone_type        varchar(20)  not null,   -- SCHOOL | HOSPITAL | LOW_EMISSION | COMPLEX_JUNCTION | DEPOT
   speed_limit_kmh  int,
   center_lon float, center_lat float, radius_m int,
   zone_geom        geometry(6000)
) order by zone_id unsegmented all nodes;

-- circular zones are declared as (center, radius in meters); a 32-vertex polygon is built with ordered LISTAGG.
-- School zones / complex junctions are anchored ON a bus line ("line 4, 2.1 km from the terminal").
create local temporary table zone_def (zone_id int, zone_name varchar(80), zone_type varchar(20), speed_limit_kmh int,
                                       route_id int, at_km float, lon float, lat float, radius_m int) on commit preserve rows;
insert into zone_def
          select 101, 'Gordon Elementary School',        'SCHOOL', 30,  2,  3.0, null, null, 220
union all select 102, 'Balfour School',                  'SCHOOL', 30,  3,  1.6, null, null, 220
union all select 103, 'Jaffa Ajyal School',              'SCHOOL', 30,  5,  3.2, null, null, 240
union all select 104, 'Ramat Aviv Alumot School',        'SCHOOL', 30,  1,  7.6, null, null, 240
union all select 105, 'Ramat Gan Hillel School',         'SCHOOL', 30,  4,  6.3, null, null, 240
union all select 106, 'Holon Shazar School',             'SCHOOL', 30,  6,  1.4, null, null, 240
union all select 107, 'Givatayim Borochov School',       'SCHOOL', 30, 10,  1.2, null, null, 230
union all select 108, 'Bnei Brak Central School',        'SCHOOL', 30,  4,  9.2, null, null, 240
union all select 109, 'Kiryat Ono Rimonim School',       'SCHOOL', 30,  8,  8.2, null, null, 230
union all select 110, 'Atidim Tech High School',         'SCHOOL', 30, 12,  2.4, null, null, 230
union all select 201, 'Ichilov Medical Center',          'HOSPITAL', 40, null, null, 34.7895, 32.0803, 300
union all select 202, 'Sheba Medical Center',            'HOSPITAL', 40, null, null, 34.8440, 32.0457, 380
union all select 203, 'Wolfson Medical Center',          'HOSPITAL', 40, null, null, 34.7610, 32.0365, 300
union all select 204, 'Beilinson Medical Center',        'HOSPITAL', 40, null, null, 34.8650, 32.0900, 320
union all select 401, 'Azrieli / Ayalon Interchange',    'COMPLEX_JUNCTION', null, null, null, 34.7920, 32.0745, 260
union all select 402, 'Allenby - Rothschild Junction',   'COMPLEX_JUNCTION', null, null, null, 34.7720, 32.0640, 200
union all select 403, 'Mesubim Interchange',             'COMPLEX_JUNCTION', null, null, null, 34.8250, 32.0330, 280
union all select 501, 'Depot North (Reading)',           'DEPOT', 20, null, null, 34.7905, 32.1050, 260
union all select 502, 'Depot South (Holon)',             'DEPOT', 20, null, null, 34.7905, 32.0190, 260
union all select 503, 'Depot East (Petah Tikva)',        'DEPOT', 20, null, null, 34.8700, 32.0935, 260;

insert into zones
with centers as (
   select d.zone_id, d.zone_name, d.zone_type, d.speed_limit_kmh, d.radius_m,
          nvl(d.lon, rp.lon) as clon, nvl(d.lat, rp.lat) as clat
   from zone_def d left join route_posts rp on rp.route_id = d.route_id and rp.idx = (d.at_km * 1000 / 50)::int
)
select c.zone_id, c.zone_name, c.zone_type, c.speed_limit_kmh, c.clon, c.clat, c.radius_m,
       ST_GeomFromText('POLYGON((' ||
          listagg( (c.clon + c.radius_m / (111320 * cos(radians(c.clat))) * cos(2 * pi() * (k.n % 32) / 32))::numeric(10,6)::varchar || ' ' ||
                   (c.clat + c.radius_m / 110540.0                       * sin(2 * pi() * (k.n % 32) / 32))::numeric(10,6)::varchar
                   using parameters max_length = 4000, separator = ',') within group (order by k.n) || '))')
from centers c cross join (select n from numbers where n <= 32) k
group by 1, 2, 3, 4, 5, 6, 7;

-- the city-center Low Emission Zone is a hand-drawn polygon
insert into zones select 301, 'City Center Low-Emission Zone', 'LOW_EMISSION', null, 34.781, 32.077, null,
   ST_GeomFromText('POLYGON((34.7610 32.0600, 34.7960 32.0560, 34.8005 32.0950, 34.7730 32.0985, 34.7610 32.0600))');
commit;

-- final route posts: each one knows its successor (LEAD) and whether it lies inside a school zone / complex junction
create table route_points (
   route_id int not null,  idx int not null,
   lon float not null,     lat float not null,
   lon_next float,         lat_next float,
   in_school_zone int,     in_complex_junction int
) order by route_id, idx unsegmented all nodes;

insert into route_points
select p.route_id, p.idx, p.lon, p.lat,
       nvl(lead(p.lon) over (partition by p.route_id order by p.idx), p.lon),
       nvl(lead(p.lat) over (partition by p.route_id order by p.idx), p.lat),
       nvl(f.in_school, 0), nvl(f.in_junction, 0)
from route_posts p
left join (select rp.route_id, rp.idx,
                  max(case when z.zone_type = 'SCHOOL' then 1 else 0 end)           as in_school,
                  max(case when z.zone_type = 'COMPLEX_JUNCTION' then 1 else 0 end) as in_junction
           from route_posts rp join zones z      -- 60 m margin: the vehicle knows the zone is coming
                on ST_Distance(STV_GeographyPoint(rp.lon, rp.lat), STV_GeographyPoint(z.center_lon, z.center_lat)) <= z.radius_m + 60
           where z.zone_type in ('SCHOOL', 'COMPLEX_JUNCTION')
           group by 1, 2) f on f.route_id = p.route_id and f.idx = p.idx;
drop table route_posts;

select zone_type, count(*) as zones, min(speed_limit_kmh) as "limit km/h",
       (sum(ST_Area(ST_GeographyFromText(ST_AsText(zone_geom)))) / 1e6)::numeric(8,2) as "ST_Area (km2)"
from zones group by 1 order by 1;

-- hospitals / depots / fast-charging hubs as points of interest
create table facilities (
   facility_id int not null primary key, facility_name varchar(80), facility_type varchar(20),
   lon float, lat float, geog geography(100)
) order by facility_id unsegmented all nodes;
insert into facilities
select zone_id, zone_name, zone_type, center_lon, center_lat, STV_GeographyPoint(center_lon, center_lat)
from zones where zone_type in ('HOSPITAL', 'DEPOT');
insert into facilities
select id, name, 'CHARGING_HUB', lon, lat, STV_GeographyPoint(lon, lat) from (
          select 601 id, 'Savidor Fast-Charge Hub' name, 34.7982 lon, 32.0837 lat
union all select 602, 'University Terminal Chargers', 34.8044, 32.1133
union all select 603, 'Jaffa Terminal Chargers',      34.7565, 32.0550
union all select 604, 'Airport T3 Chargers',          34.8708, 32.0005
union all select 605, 'Herzliya Terminal Chargers',   34.8447, 32.1624) c;
commit;

-- =====================================================================================
\! echo; tput rev 2>/dev/null; echo " 1.3  The fleet: autonomous e-buses, human-driven e-buses, human-driven diesel     "; tput sgr0 2>/dev/null
-- =====================================================================================
create table vehicles (
   vehicle_id      int          not null primary key,
   plate           varchar(12)  not null,
   drive_mode      varchar(12)  not null,     -- AUTONOMOUS | HUMAN
   powertrain      varchar(8)   not null,     -- EV | DIESEL
   fleet_segment   varchar(24)  not null,     -- Autonomous EV | Human EV | Human Diesel
   manufacturer    varchar(30),
   model           varchar(40),
   battery_kwh     int,
   tank_l          int,
   operator_id     varchar(16),               -- driver badge or AV software stack
   route_id        int          not null,
   depot_id        int          not null,
   in_service_date date
) order by vehicle_id unsegmented all nodes;

-- every line gets the SAME mix of segments -> AV vs. human is compared on identical roads and timetables
insert into vehicles
select 1000 + n,
       'TLV-' || (1000 + n)::varchar,
       case when n % 16 < 5 then 'AUTONOMOUS' else 'HUMAN' end,
       case when n % 16 < 11 then 'EV' else 'DIESEL' end,
       case when n % 16 < 5 then 'Autonomous EV' when n % 16 < 11 then 'Human EV' else 'Human Diesel' end,
       case when n % 16 < 5 then 'Helios Mobility' when n % 16 < 11 then 'Voltera' else 'Magnus' end,
       case when n % 16 < 5 then 'Helios A12 AutoPilot (L4)' when n % 16 < 11 then 'Voltera E-City 12' else 'Magnus D12 Euro VI' end,
       case when n % 16 < 5 then 480 when n % 16 < 11 then 540 end,
       case when n % 16 >= 11 then 300 end,
       case when n % 16 < 5 then 'AV-STACK-4.2' else 'DRV-' || (5000 + n)::varchar end,
       1 + n % 12,
       501 + (n % 12) % 3,
       '2021-01-01'::date + (abs(hash(n, 'svc')) % 1500)::int
from numbers where n between 1 and :FLEET_SIZE;
commit;

select fleet_segment, drive_mode, powertrain, model, count(*) as vehicles, count(distinct route_id) as lines_served,
       repeat('█', (count(*) / 4)::int) as " "
from vehicles group by 1, 2, 3, 4 order by 1;

-- ---- hidden simulator inputs (a real fleet does not have these tables - the ML has to DISCOVER them) ------
-- driving style: 0 = perfectly smooth ... 1 = very aggressive.  The AV stack is smooth and consistent.
create table sim_vehicle_profile as
select vehicle_id,
       case when drive_mode = 'AUTONOMOUS' then 0.05
            else 0.15 + 0.85 * (abs(hash(vehicle_id, 'style')) % 10000) / 10000.0 end              as aggr,
       (abs(hash(vehicle_id, 'phase')) % 10000) / 10000.0                                          as phase,
       (abs(hash(vehicle_id, 'offs')) % 30000)::float                                              as start_offset_m,
       20000 + (abs(hash(vehicle_id, 'odo')) % 260000)::float                                      as base_odo_km,
       ((abs(hash(vehicle_id, 'b1')) % 1000) / 1000.0 - 0.5) * 4                                   as bias_temp,
       ((abs(hash(vehicle_id, 'b2')) % 1000) / 1000.0 - 0.5) * 0.06                                as bias_vib,
       ((abs(hash(vehicle_id, 'b3')) % 1000) / 1000.0 - 0.5) * 4                                   as bias_psi
from vehicles;

-- component failures: a wear signature builds up during the 10 days before the breakdown.
-- hard-driven vehicles fail more often.  Failures dated AFTER the last telemetry day are the ones still preventable.
create table sim_failure_plan as
select v.vehicle_id,
       case when abs(hash(v.vehicle_id, 'comp')) % 100 < 38 then 'DRIVETRAIN'
            when abs(hash(v.vehicle_id, 'comp')) % 100 < 68 then 'TIRE'
            when abs(hash(v.vehicle_id, 'comp')) % 100 < 84 then 'COOLING'
            else 'ELECTRICAL' end                                                                   as component,   -- ELECTRICAL = sudden, no warning
       (9 + abs(hash(v.vehicle_id, 'fday')) % (:DEMO_DAYS + 1))::int                               as fail_day_idx,
       (3600 + abs(hash(v.vehicle_id, 'fsec')) % 50000)::int                                       as fail_svc_sec
from vehicles v join sim_vehicle_profile p using (vehicle_id)
where (abs(hash(v.vehicle_id, 'fails')) % 1000) / 1000.0 < 0.07 + 0.22 * p.aggr;

-- benign look-alikes: a few days of raised vibration (unbalanced wheel, rough diversion) that do NOT end in a breakdown
create table sim_benign_episode as
select vehicle_id,
       (abs(hash(vehicle_id, 'bstart')) % :DEMO_DAYS)::int       as start_day_idx,
       (2 + abs(hash(vehicle_id, 'blen')) % 4)::int              as len_days,
       0.04 + (abs(hash(vehicle_id, 'bamp')) % 50) / 1000.0      as vib_add
from vehicles where abs(hash(vehicle_id, 'benign')) % 100 < 14;

-- hourly weather feed (ambient temperature drives HVAC load and battery behaviour, rain drives risk)
create table weather_hourly (
   day_idx int not null, hr int not null, ts_hour timestamp not null, temp_c numeric(4,1), is_rain int, rain_mm numeric(4,1)
) order by day_idx, hr unsegmented all nodes;
insert into weather_hourly
select d.n, h.n,
       timestampadd(hour, h.n, (current_date - :DEMO_DAYS + d.n)::timestamp),
       (20 + 9 * sin(2 * pi() * d.n / 45.0 + 1) + 5 * sin(2 * pi() * (h.n - 9) / 24.0) + (abs(hash(d.n, h.n)) % 20) / 10.0 - 1)::numeric(4,1),
       case when (d.n % 7 = 3 and h.n between 6 and 14) or d.n % 11 = 6 then 1 else 0 end,
       case when (d.n % 7 = 3 and h.n between 6 and 14) or d.n % 11 = 6 then 0.5 + (abs(hash(d.n, h.n, 'r')) % 60) / 10.0 else 0 end
from (select n from numbers where n < :DEMO_DAYS) d cross join (select n from numbers where n < 24) h;
commit;

-- =====================================================================================
\! echo; tput rev 2>/dev/null; echo " 1.4  IoT telemetry: simulate the whole fleet INSIDE Vertica with one SQL statement "; tput sgr0 2>/dev/null
-- =====================================================================================
-- Encodings are chosen per column the way Database Designer would: RLE for long runs, COMMONDELTA for counters,
-- DELTARANGE for slowly moving floats (GPS!), BLOCKDICT for low-cardinality sensors.
create table telemetry (
   event_id        int           not null encoding COMMONDELTA_COMP,
   vehicle_id      int           not null encoding RLE,
   ts              timestamp     not null encoding DELTARANGE_COMP,
   lat             float         not null encoding DELTARANGE_COMP,   -- GPS
   lon             float         not null encoding DELTARANGE_COMP,
   speed_kmh       numeric(5,1),
   accel_ms2       numeric(5,2),                                      -- longitudinal acceleration (IMU); <= -3.2 is a harsh brake
   odometer_km     numeric(9,1)  encoding DELTARANGE_COMP,
   power_kw        numeric(6,1),                                      -- EV  : battery power (+ traction / - regeneration) incl. HVAC
   fuel_lph        numeric(5,1),                                      -- ICE : fuel rate, liters per hour
   energy_pct      numeric(5,1)  encoding COMMONDELTA_COMP,           -- state of charge (EV) or tank level (diesel)
   motor_temp_c    numeric(5,1),                                      -- traction motor / engine temperature
   batt_temp_c     numeric(5,1)  encoding BLOCKDICT_COMP,
   vibration_g     numeric(5,3),                                      -- drivetrain vibration RMS
   tire_psi        numeric(5,1)  encoding BLOCKDICT_COMP,
   outside_temp_c  numeric(4,1),
   passengers      int           encoding BLOCKDICT_COMP,
   brake_pedal     int           encoding BLOCKDICT_COMP,
   abs_on          int           encoding RLE,
   wipers_on       int           encoding RLE,
   headlamps_on    int           encoding RLE,
   doors_open      int           encoding BLOCKDICT_COMP,
   av_disengage    int           encoding RLE                         -- AV only: safety operator had to take over
)
order by vehicle_id, ts
segmented by hash(vehicle_id) all nodes
partition by ts::date;                       -- daily partitions: instant purge / archive of old IoT data

\echo 'Generating' :FLEET_SIZE 'vehicles x' :DEMO_DAYS 'days, one event every' :SAMPLE_SEC 'seconds (06:00-22:00 service) ...'
\timing on
insert into telemetry
with grid as (                    -- vehicle x day x sample slot; 3% of the messages are lost (cellular dead spots)
   select v.vehicle_id, v.drive_mode, v.powertrain, v.route_id, v.battery_kwh, v.tank_l,
          p.aggr, p.phase, p.start_offset_m, p.base_odo_km, p.bias_temp, p.bias_vib, p.bias_psi,
          62 - 12 * p.aggr                         as t_move,      -- seconds to drive stop-to-stop: aggressive = hurry up and wait
          d.n                                      as day_idx,
          k.n * :SAMPLE_SEC + randomint(20)        as svc_sec,     -- seconds since 06:00, with jitter
          (d.n * :FLEET_SIZE + v.vehicle_id - 1001) * (57600 // :SAMPLE_SEC) + k.n + 1 as event_id
   from vehicles v
        join sim_vehicle_profile p using (vehicle_id)
        cross join (select n from numbers where n < :DEMO_DAYS) d
        cross join (select n from numbers where n < 57600 // :SAMPLE_SEC) k
   where random() > 0.03
     and not (v.vehicle_id = 1001 and d.n = :DEMO_DAYS - 1 and k.n * :SAMPLE_SEC between 36000 and 36000 + 480)   -- a tunnel
), kin as (                       -- timetable: a 113 s stop-to-stop cycle; cosine speed profile between stops, then dwell
   select g.*, r.stop_spacing_m as d_stop, r.speed_limit_kmh, rl.len_m,
          floor(g.svc_sec / 113.0 + g.phase)                               as n_cyc,
          (g.svc_sec / 113.0 + g.phase) - floor(g.svc_sec / 113.0 + g.phase) as ph
   from grid g join routes r using (route_id)
        join (select route_id, max(idx) * 50.0 as len_m from route_points group by 1) rl using (route_id)
), motion as (
   select k.*,
          case when ph < t_move / 113 then 1 else 0 end                                                              as moving,
          case when ph < t_move / 113 then (pi() / 2) * sin(pi() * ph * 113 / t_move) * d_stop / t_move else 0 end      as v_ms,
          case when ph < t_move / 113 then (pi() * pi() / 2) * cos(pi() * ph * 113 / t_move) * d_stop / (t_move * t_move) else 0 end as a_ms2,
          (n_cyc + case when ph < t_move / 113 then (1 - cos(pi() * ph * 113 / t_move)) / 2 else 1 end) * d_stop         as dist_today_m
   from kin k
), placed as (                    -- ping-pong along the line, snap to the 50 m posts
   select m.*,
          case when fold_m > len_m then 2 * len_m - fold_m else fold_m end as pos_m
   from (select *, (dist_today_m + start_offset_m) - floor((dist_today_m + start_offset_m) / (2 * len_m)) * (2 * len_m) as fold_m from motion) m
), env as (
   select p.*, rp.lon as p_lon, rp.lat as p_lat, rp.lon_next, rp.lat_next, rp.in_school_zone, rp.in_complex_junction,
          (p.pos_m - rp.idx * 50) / 50.0                                   as seg_frac,
          w.temp_c + (random() - 0.5)                                       as amb_c,
          w.is_rain,
          6 + (p.svc_sec // 3600)                                          as hr,
          dayofweek(current_date - :DEMO_DAYS + p.day_idx)                  as dow,
          fp.component,
          nvl(be.vib_add, 0)                                                as benign_vib,
          ((abs(hash(p.vehicle_id, p.day_idx, 'dv')) % 1000) / 1000.0 - 0.5) as day_drift_1,   -- day-to-day sensor drift (load, road works, calibration)
          ((abs(hash(p.vehicle_id, p.day_idx, 'dt')) % 1000) / 1000.0 - 0.5) as day_drift_2,
          case when fp.vehicle_id is null then 0
               when (fp.fail_day_idx - p.day_idx) * 86400 + fp.fail_svc_sec - p.svc_sec < 0 then 0           -- repaired: healthy again
               else greatest(0, 1 - ((fp.fail_day_idx - p.day_idx) * 86400 + fp.fail_svc_sec - p.svc_sec) / 864000.0) end as wear,
          (fp.fail_day_idx - p.day_idx) * 86400 + fp.fail_svc_sec - p.svc_sec  as sec_to_fail,
          random() as r1, random() as r2, random() as r3, random() as r4, random() as r5, random() as r6, random() as r7,
          random() + random() + random() - 1.5 as g1, random() + random() + random() - 1.5 as g2,
          random() + random() + random() - 1.5 as g3, random() + random() + random() - 1.5 as g4
   from placed p
        join route_points rp on rp.route_id = p.route_id and rp.idx = floor(p.pos_m / 50)
        join weather_hourly w on w.day_idx = p.day_idx and w.hr = 6 + (p.svc_sec // 3600)
        left join sim_failure_plan fp on fp.vehicle_id = p.vehicle_id
        left join sim_benign_episode be on be.vehicle_id = p.vehicle_id and p.day_idx between be.start_day_idx and be.start_day_idx + be.len_days
), behaviour as (
   select e.*,
          -- braking / acceleration EVENTS: intensity = 1.0 + Exp(0.9) m/s2, so the tail decays smoothly; >= 3.2 m/s2 is a harsh brake.
          -- 11.5 = exp(2.2 / 0.9): the event rate is scaled so that the HARSH rate is the first factor (AV 0.08%, humans 0.2% - 1.8% of readings)
          case when moving = 1 and v_ms > 3 and r1 < 11.5 * case when drive_mode = 'AUTONOMOUS' then 0.0008 * (1 + 0.5 * is_rain) * (case when in_complex_junction = 1 then 1.5 else 1 end)
                     else (0.002 + 0.016 * aggr * aggr) * (1 + 0.6 * is_rain) * (case when hr in (7, 8, 16, 17, 18) then 1.3 else 1 end)
                          * (case when in_complex_junction = 1 then 4 else 1 end) end
               then 1.0 - 0.9 * ln(1 - 0.99778 * r6) else 0 end                                                   as brake_mag,      -- truncated at 6.5 m/s2
          case when moving = 1 and r2 < 20.1 * case when drive_mode = 'AUTONOMOUS' then 0.0001 else 0.001 + 0.010 * aggr * aggr end
               then 0.8 - 0.6 * ln(1 - 0.99654 * r7) else 0 end                                                   as accel_mag,      -- truncated at 4.2; >= 2.6 is harsh
          13500 + 70 * round(80 * case when hr in (7, 8, 16, 17, 18) then 0.70 when hr between 9 and 15 then 0.42 else 0.18 end
                              * case when dow in (6, 7) then 0.5 else 1 end * (0.5 + r3))                          as mass_kg,
          2.5 + 0.30 * abs(amb_c - 21)                                                                              as aux_kw
   from env e
   where sec_to_fail is null or sec_to_fail >= 0 or sec_to_fail < -129600     -- 1.5 days in the workshop after a breakdown
), physics as (                   -- traction power = (inertia + rolling resistance + aero drag) x speed
   select b.*,
          case when brake_mag >= 3.2 then 1 else 0 end as harsh_brake,
          case when brake_mag < 3.2 and accel_mag >= 2.6 then 1 else 0 end as harsh_accel,
          (mass_kg * a_ms2 + 0.008 * mass_kg * 9.81 + 0.5 * 1.2 * 5.6 * v_ms * v_ms) * v_ms / 1000 as trac_kw
   from behaviour b
), sensors as (
   select ph.*,
          case when powertrain = 'EV' then
               case when trac_kw >= 0 then trac_kw / 0.90
                    else trac_kw * case when harsh_brake = 1 then 0.15 else 0.72 - 0.25 * aggr end end + aux_kw end       as power_kw_raw,
          case when powertrain = 'DIESEL' then 1.5 + (greatest(trac_kw, 0) / 0.42 + aux_kw / 0.30) / 9.9 end               as fuel_lph_raw,
          least(case when drive_mode = 'AUTONOMOUS' then case when in_school_zone = 1 and hr between 7 and 16 then 26 + 2 * r4 else speed_limit_kmh end else 999 end,
                case when drive_mode = 'HUMAN' and in_school_zone = 1 and hr between 7 and 16 and r5 > aggr * 0.75 then 27 + 4 * r4 else 999 end,
                v_ms * 3.6 * (1 + 0.03 * g1)
                   + case when drive_mode = 'HUMAN' and moving = 1 and v_ms > 5 and r4 < 0.05 * aggr then 8 + 18 * r5 else 0 end) as speed_raw
   from physics ph
)
select event_id, vehicle_id,
       timestampadd(second, 21600 + svc_sec, (current_date - :DEMO_DAYS + day_idx)::timestamp),
       round(p_lat + (lat_next - p_lat) * seg_frac + (r3 - 0.5) * 0.00012
             + case when vehicle_id in (1138, 1207, 1293) and day_idx = :DEMO_DAYS - 1 - vehicle_id % 9 and svc_sec between 28800 and 31200
                    then 0.0060 * sin(pi() * (svc_sec - 28800) / 2400.0) else 0 end, 6),
       round(p_lon + (lon_next - p_lon) * seg_frac + (r2 - 0.5) * 0.00012
             + case when vehicle_id in (1138, 1207, 1293) and day_idx = :DEMO_DAYS - 1 - vehicle_id % 9 and svc_sec between 28800 and 31200
                    then 0.0070 * sin(pi() * (svc_sec - 28800) / 2400.0) else 0 end, 6),
       greatest(speed_raw, 0),
       case when brake_mag > 0 then -brake_mag when accel_mag > 0 then accel_mag else a_ms2 * (1 + 0.4 * aggr) + 0.08 * g2 end,
       base_odo_km + day_idx * (57600 / 113.0) * d_stop / 1000 + dist_today_m / 1000,
       power_kw_raw,
       fuel_lph_raw,
       case when powertrain = 'EV'
            then greatest(0.5, 97 - 100 * sum(power_kw_raw * :SAMPLE_SEC / 3600.0) over (partition by vehicle_id, day_idx order by svc_sec) / battery_kwh)
            else 98 - 100 * sum(fuel_lph_raw * :SAMPLE_SEC / 3600.0) over (partition by vehicle_id, day_idx order by svc_sec) / tank_l end,
       case when powertrain = 'EV' then 52 + 0.45 * (amb_c - 20) + 0.06 * greatest(trac_kw, 0) else 86 + 0.30 * (amb_c - 20) + 0.05 * greatest(trac_kw, 0) end
            + 1.5 * g3 + bias_temp + 2.4 * day_drift_2
            + case component when 'COOLING' then 22 * wear * wear when 'DRIVETRAIN' then 6 * wear * wear else 0 end,
       case when powertrain = 'EV' then 27 + 0.5 * (amb_c - 20) + 0.02 * abs(power_kw_raw) + 0.8 * g4 end,
       0.28 + case when powertrain = 'DIESEL' then 0.12 else 0 end + 0.006 * v_ms * 3.6 + 0.04 * g4 + bias_vib + 0.03 * day_drift_1 + benign_vib
            + case when component = 'DRIVETRAIN' then 0.30 * wear * wear else 0 end,
       112 + 0.12 * (amb_c - 20) + 0.8 * g1 + bias_psi + 1.2 * day_drift_2 - case when component = 'TIRE' then 18 * power(wear, 1.5) else 0 end,
       amb_c,
       (mass_kg - 13500) / 70,
       case when moving = 0 or a_ms2 < -0.15 or brake_mag > 0 then 1 else 0 end,
       case when harsh_brake = 1 and (is_rain = 1 or r4 < 0.25) then 1 else 0 end,
       is_rain,
       case when hr < 7 or hr >= 18 or is_rain = 1 then 1 else 0 end,
       case when moving = 0 then 1 else 0 end,
       case when drive_mode = 'AUTONOMOUS'
            then case when moving = 1 and r3 < 0.0004 * (1 + is_rain) * (case when in_complex_junction = 1 then 25 else 1 end) then 1 else 0 end end
from sensors;
commit;
\timing off

-- =====================================================================================
\! echo; tput rev 2>/dev/null; echo " 1.5  Operational systems of record: safety incidents and workshop log             "; tput sgr0 2>/dev/null
-- =====================================================================================
-- incident reports (near-miss camera triggers, minor and major collisions)
create table incidents (
   incident_id int not null, vehicle_id int not null, ts timestamp not null, lat float, lon float,
   severity varchar(12), trigger_type varchar(24), speed_kmh numeric(5,1), is_rain int
) order by ts unsegmented all nodes;
insert into incidents
select row_number() over (order by ts), vehicle_id, ts, lat, lon,
       case when r < 0.78 then 'NEAR_MISS' when r < 0.96 then 'MINOR' else 'MAJOR' end,
       case when accel_ms2 <= -3.2 then 'HARSH_BRAKE' else 'THIRD_PARTY' end, speed_kmh, wipers_on
from (select *, random() as r, random() as pick from telemetry) t
where (accel_ms2 <= -3.2 and pick < 0.004 + 0.00010 * speed_kmh) or pick < 0.0000025;

-- workshop log: unplanned breakdowns (from the wear plan) and routine services
create table maintenance_log (
   work_order_id int not null, vehicle_id int not null, event_ts timestamp not null,
   event_type varchar(12), component varchar(16), downtime_hours int, cost_usd int
) order by vehicle_id, event_ts unsegmented all nodes;
insert into maintenance_log
select row_number() over (order by event_ts), vehicle_id, event_ts, event_type, component, downtime_hours, cost_usd from (
   select vehicle_id,
          timestampadd(second, 21600 + fail_svc_sec, (current_date - :DEMO_DAYS + fail_day_idx)::timestamp) as event_ts,
          'BREAKDOWN' as event_type, component,
          36 as downtime_hours,
          case component when 'DRIVETRAIN' then 14500 when 'COOLING' then 6800 when 'ELECTRICAL' then 5200 else 2900 end + abs(hash(vehicle_id, 'cost')) % 1500 as cost_usd
   from sim_failure_plan where fail_day_idx < :DEMO_DAYS
   union all
   select vehicle_id,
          timestampadd(hour, 22, (current_date - :DEMO_DAYS + abs(hash(vehicle_id, 'pm')) % :DEMO_DAYS)::timestamp),
          'SCHEDULED', 'INSPECTION', 4, 450 + abs(hash(vehicle_id, 'pmc')) % 300
   from vehicles) x;
commit;

select analyze_statistics('FLEET.telemetry');
select analyze_statistics('FLEET.vehicles');

-- =====================================================================================
\! echo; tput rev 2>/dev/null; echo " 1.6  What did we just build?                                                      "; tput sgr0 2>/dev/null
-- =====================================================================================
select 'telemetry (IoT events)' as "table", to_char(count(*), '999,999,999') as "rows" from telemetry
union all select 'vehicles',        to_char(count(*), '999,999,999') from vehicles
union all select 'routes',          to_char(count(*), '999,999,999') from routes
union all select 'zones (geofences)', to_char(count(*), '999,999,999') from zones
union all select 'incidents',       to_char(count(*), '999,999,999') from incidents
union all select 'maintenance_log', to_char(count(*), '999,999,999') from maintenance_log;

select to_char(min(ts), 'YYYY-MM-DD HH24:MI') as first_event, to_char(max(ts), 'YYYY-MM-DD HH24:MI') as last_event,
       count(distinct vehicle_id) as vehicles, count(distinct ts::date) as days,
       to_char(max(odometer_km) , '999,999') as max_odometer_km
from telemetry;

\echo 'Columnar storage: sorted + encoded + compressed automatically - a big deal for never-ending IoT streams.'
\echo '(raw size = the same events written as a CSV file, measured on a 1% sample)'
select to_char(ps.n, '999,999,999')                        as "rows",
       (ps.bytes / 1024^2)::numeric(10,1)                  as vertica_mb,
       (ps.n * csv.avg_len / 1024^2)::numeric(10,1)        as raw_csv_mb,
       (ps.n * csv.avg_len / ps.bytes)::numeric(6,1) || ' : 1' as compression_ratio,
       (ps.bytes / ps.n)::numeric(6,1)                     as bytes_per_event
from (select sum(row_count) as n, sum(used_bytes) as bytes from projection_storage
      where anchor_table_schema = 'FLEET' and anchor_table_name = 'telemetry') ps,
     (select avg(length(event_id::varchar || vehicle_id::varchar || ts::varchar || lat::varchar || lon::varchar || speed_kmh::varchar || accel_ms2::varchar
                        || odometer_km::varchar || nvl(power_kw::varchar, '') || nvl(fuel_lph::varchar, '') || energy_pct::varchar || motor_temp_c::varchar
                        || nvl(batt_temp_c::varchar, '') || vibration_g::varchar || tire_psi::varchar || outside_temp_c::varchar || passengers::varchar
                        || '000000') + 23) as avg_len
      from telemetry where event_id % 100 = 0) csv;

\! echo; tput rev 2>/dev/null; echo " Part 1 done.  Next:  vsql -f 02_smart_fleet_analytics.sql "; tput sgr0 2>/dev/null
