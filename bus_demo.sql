--
-- To run this demo in QA env do:    /opt/vertica/bin/vsql -ef BUS_DEMO.sql
-- This is only an example not intend to run in production
--
\set DEMO_ROWS 10000000
drop schema IF EXISTS BUS cascade;
create schema BUS;
set search_path to BUS;

\! echo ; tput rev; printf "%s\n" "Starting to create schema.."; tput sgr0

create table BUS.Bus_Events (
   event_id            int,   -- 0 Event_id generated from row_number
   vin_id              int,   -- 1 Randomly generated Vehicle Identification Number; Random number from 0-100 
   vin_model           int,   -- 2 Vehicle model is used to define which events are exceptional for specific models; Random number from 0-20
   outsidet            int,   -- 3 Outside temperature, The outside temperature where the vehicle is driving	Random number from 0-50
   enginet             int,   -- 4 Engine temperature, The engine temperature of the vehicle	Random number from 0-500
   speed               int,   -- 5 Engine speed at which the vehicle is driving, Random number from 0-100
   fuel                int,   -- 6 Fuel level of the vehicle, Random number from 0-100 (indicates fuel level percentage)
   e_oil               int,   -- 7 Engine oil level of the vehicle	Random number from 0-100 (indicates engine oil level percentage)
   tire_p              int,   -- 8 Tire pressure of the vehicle, Random number from 0-50 indicates tire pressure PSI (pounds per square inch)
   odometer            int,   -- 9 The odometer reading is the measured distance travelled by a vehicle. Random number from 0-200000
   a_p_position        int,   --10 The accelerator pedal position of the vehicle, Random number from 0-100 (accelerator level percentage)
   Parking_brake_stat  int,   --11 Indicates whether the vehicle is parked or not, True or False
   Headlamp_stat       int,   --12 Indicates where the headlamp is on or not	True or False
   Brake_pedal_stat    int,   --13 Indicates whether the brake pedal is pressed or not	True or False
   Trans_gear_position int,   --14 The transmission gear position of the vehicle States: 1=first, 2=second, 3=third, 4=fourth, 5=fifth, 6=sixth
   Ignition_stat       int,   --15 Indicates whether the vehicle is running or stopped, True or False
   Windshield_wiper_stat int, --16 Indicates whether the windshield wiper is turned or not, True or False
   abs                 int,   --17 indicates whether ABS is engaged or not, True or False
   vtimestamp    timestamp,   --18 The timestamp when the data point is created	Date
   vlongitude        float,   --19 The longitude location of the vehicle; 
   vlatitude          float   --20 The latitude location of the vehicle; 
   )
   order by vin_id, vtimestamp, fuel, odometer
	UNSEGMENTED ALL NODES;

CREATE PROJECTION Bus_Events_Projection02
(
 event_id ENCODING DELTAVAL, 
 vin_id ENCODING DELTAVAL, 
 vin_model ENCODING BLOCKDICT_COMP, 
 outsidet ENCODING DELTAVAL, 
 enginet ENCODING DELTAVAL, 
 speed ENCODING RLE, 
 fuel ENCODING DELTAVAL, 
 e_oil ENCODING DELTAVAL, 
 tire_p ENCODING DELTAVAL, 
 odometer ENCODING DELTAVAL, 
 a_p_position ENCODING DELTAVAL, 
 Parking_brake_stat ENCODING BLOCKDICT_COMP, 
 Headlamp_stat ENCODING BLOCKDICT_COMP, 
 Brake_pedal_stat ENCODING RLE, 
 Trans_gear_position ENCODING RLE, 
 Ignition_stat ENCODING BLOCKDICT_COMP, 
 Windshield_wiper_stat ENCODING BLOCKDICT_COMP, 
 abs ENCODING BLOCKDICT_COMP, 
 vtimestamp ENCODING RLE, 
 vlongitude ENCODING BLOCKDICT_COMP, 
 vlatitude ENCODING BLOCKDICT_COMP
)
AS
 SELECT event_id, 
        vin_id, 
        vin_model, 
        outsidet, 
        enginet, 
        speed, 
        fuel, 
        e_oil, 
        tire_p, 
        odometer, 
        a_p_position, 
        Parking_brake_stat, 
        Headlamp_stat, 
        Brake_pedal_stat, 
        Trans_gear_position, 
        Ignition_stat, 
        Windshield_wiper_stat, 
        abs, 
        vtimestamp, 
        vlongitude, 
        vlatitude
 FROM BUS.Bus_Events 
 ORDER BY Trans_gear_position,
          speed,
          Brake_pedal_stat,
          vtimestamp,
          event_id
UNSEGMENTED ALL NODES;

-- select refresh('BUS.Bus_Events');
-- select make_ahm_now();

\! tput rev; printf "\n %s" "Starting to generate in Vertica "
\echo -n :DEMO_ROWS
\! printf "%s\n" " random events and load those to the database.."; tput sgr0

\timing on
insert into BUS.BUS_EVENTS
with myrows as (select row_number() over() as id, 
randomint(100) as r100,
randomint(10000) as r10k
from ( select 1 from ( select now() as se union all select now() 
+ :DEMO_ROWS
 - 1 as se) a timeseries ts as '1 day' over (order by se)) b)
select 
id, r10k + 100000000, r10k // 500 , r100, r100 + 25, randomint(90), randomint(100), randomint(100), randomint(50), 
randomint(200000), randomint(100), randomint(2), randomint(2), randomint(2), randomint(6), randomint(2), randomint(2), randomint(2), 
CURRENT_TIME(0)::timestamp - randomint(365) , randomint(50), randomint(50)
from myrows;

\! echo ; tput rev; echo "Load 10 test events as a control group for Plate# 11, 2 fuel fills, 300K and 200K Meter in between the 2 fills"; tput sgr0
COPY BUS.BUS_EVENTS FROM STDIN DELIMITER ',' ABORT ON ERROR;
9000001,11,111,20,45,67, 10,123,15,1,46,1,0,0,3,0,1,1,2022-03-10 11:19:17,5,17
9000002,11,111,19,44,32,  9,123,17,1,85,1,0,1,0,1,1,0,2022-03-11 12:19:17,33,35
9000003,11,111,19,44,32,  8,123,17,300001,85,1,0,1,0,1,1,0,2022-03-12 13:19:17,33,35
9000004,11,111,19,44,32,100,123,17,300002,85,1,0,1,0,1,1,0,2022-03-13 14:19:17,33,35
9000005,11,111,19,44,32,222,123,17,100,85,1,0,1,0,1,1,0,2022-03-14 15:19:17,33,35
9000006,11,111,19,44,32,220,123,17,1000,85,1,0,1,0,1,1,0,2022-03-15 13:19:17,33,35
9000007,11,111,19,44,32,210,123,17,10000,85,1,0,1,0,1,1,0,2022-03-16 12:19:17,33,35
9000008,11,111,19,44,32,200,123,17,200100,85,1,0,1,0,1,1,0,2022-03-17 10:19:17,33,35
9000009,11,111,19,44,32,222,123,17,200101,85,1,0,1,0,1,1,0,2022-03-18 11:19:17,33,35
9000010,11,111,19,44,32, 50,123,17,200102,85,1,0,1,0,1,1,0,2022-03-19 10:19:17,33,35
\.

-- On real life you may want to run analyze_statistics at this point
-- \! echo ; tput rev; echo "Starting analyze_statistics.."; tput sgr0
-- select analyze_statistics('BUS.BUS_EVENTS');

\timing off
\t
\x
\! echo ; tput rev; echo "Starting Vertica Events Stream Analytics:"; tput sgr0
select count(1) as Number_of_events from BUS.BUS_EVENTS;

\! echo ; tput rev; echo "One event example:"; tput sgr0

select * from BUS.BUS_EVENTS limit 1;
\! echo ; tput rev; echo "Starting Stream Analytics via SQL Query to get the average of all important vehicle parameters"
\! echo "like vehicle speed, engine temperature, tire pressure, engine oil level, and others."
\! echo "The averages are used to detect anomalies, issue alerts, and determine the overall health conditions of the vehicles:"; tput sgr0
\timing on

select vin_model as Model, 
       count(vin_model) as Vehicles_Count, 
       min(outsidet) as Min_Outside_Temp, max(outsidet) as max_Outside_Temp, avg(outsidet) as Avg_Outside_Temperature, 
       min(enginet) as Min_Engine_Temp, max(enginet) as max_Engine_Temp, avg(enginet) as Avg_Engine_Temperature, 
       min(speed) as Min_Speed, max(speed) as max_Speed, avg(speed)as Avg_Speed, 
       min(e_oil) as Min_Oil_Temp, max(e_oil) as max_Oil_Temp, avg(e_oil) as Avg_Oil_Temperature, 
       min(tire_p) as Min_Tire_Pressure_PSI, max(tire_p) as max_Tire_Pressure_PSI, avg(tire_p) as Avg_Tire_Pressure_PSI
from BUS.Bus_Events
group by vin_model
order by vin_model limit 1;
\x
\t

\! echo ; tput rev; echo "Detect the most 3 aggressive driving events behavior based on braking pattern at high speed on Saturdays:"; tput sgr0
with drivers as 
(select vin_id as Vehicle_Plate_Number, count(vin_id) as events_number
from BUS.Bus_Events
where Trans_gear_position IN (4,5,6) and 
      Brake_pedal_stat=1             and 
      speed >= 50                    and
      DAYOFWEEK (vtimestamp) = 7
group by vin_id)
select Vehicle_Plate_Number, events_number
from drivers
order by events_number desc limit 3;

\! echo ; tput rev; echo "Detect the 10 most fuel saving vehicles (max distance between fuel fill events):"; tput sgr0
\timing on
WITH FILLS AS
(SELECT vin_id, 
        vtimestamp,  
        fuel, 
        odometer, 
        CONDITIONAL_TRUE_EVENT(fuel > LAG(fuel) AND vin_id = LAG(vin_id)) OVER(ORDER BY vin_id, vtimestamp) AS FILL_EVENT
FROM BUS.BUS_EVENTS)
SELECT vin_id, FILL_EVENT, MAX(odometer) - MIN(odometer) as DISTANCE
FROM FILLS
GROUP BY vin_id, FILL_EVENT
ORDER BY DISTANCE DESC limit 10; 
\timing off
