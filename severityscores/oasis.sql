-- ------------------------------------------------------------------
-- Title: Oxford Acute Severity of Illness Score (OASIS)
-- MIMIC version: MIMIC-III v1.4
-- Originally written by: Alistair Johnson
-- Contact: aewj [at] mit [dot] edu
-- ------------------------------------------------------------------

-- This query extracts the Oxford acute severity of illness score.
-- This score is a measure of severity of illness for patients in the ICU.
-- The score is calculated on the first day of each ICU patients' stay.
-- The score is calculated for *all* ICU patients, with the assumption that the user will subselect appropriate ICUSTAY_IDs.
-- For example, the score is calculated for neonates, but it is likely inappropriate to actually use the score values for these patients.

-- Reference for OASIS:
--    Johnson, Alistair EW, Andrew A. Kramer, and Gari D. Clifford.
--    "A new severity of illness scale using a subset of acute physiology and chronic health evaluation data elements shows comparable predictive accuracy*."
--    Critical care medicine 41, no. 7 (2013): 1711-1718.

-- Variables used in OASIS:
--  Heart rate, GCS, MAP, Temperature, Respiratory rate, Ventilation status (sourced from CHARTEVENTS)
--  Urine output (sourced from OUTPUTEVENTS)
--  Elective surgery (sourced from ADMISSIONS and SERVICES)
--  Pre-ICU in-hospital length of stay (sourced from ADMISSIONS and ICUSTAYS)
--  Age (sourced from PATIENTS)

-- The following views are required to run this query:
--  1) uofirstday - generated by urine-output-first-day.sql
--  2) ventfirstday - generated by ventilated-first-day.sql
--  3) vitalsfirstday - generated by vitals-first-day.sql
--  4) gcsfirstday - generated by gcs-first-day.sql


-- Regarding missing values:
--  The ventilation flag is always 0/1. It cannot be missing, since VENT=0 if no data is found for vent settings.

CREATE MATERIALIZED VIEW OASIS as

with surgflag as
(
  select ie.icustay_id
    , max(case
        when lower(curr_service) like '%surg%' then 1
        when curr_service = 'ORTHO' then 1
    else 0 end) as surgical
  from icustays ie
  left join services se
    on ie.hadm_id = se.hadm_id
    and se.transfertime < ie.intime + interval '1' day
  group by ie.icustay_id
)
, cohort as
(
select ie.subject_id, ie.hadm_id, ie.icustay_id
      , ie.intime
      , ie.outtime
      , adm.deathtime
      , cast(ie.intime as timestamp) - cast(adm.admittime as timestamp) as PreICULOS
      , floor( ( cast(ie.intime as date) - cast(pat.dob as date) ) / 365.242 ) as age
      , gcs.mingcs
      , vital.heartrate_max
      , vital.heartrate_min
      , vital.meanbp_max
      , vital.meanbp_min
      , vital.resprate_max
      , vital.resprate_min
      , vital.tempc_max
      , vital.tempc_min
      , vent.mechvent
      , uo.urineoutput

      , case
          when adm.ADMISSION_TYPE = 'ELECTIVE' and sf.surgical = 1
            then 1
          when adm.ADMISSION_TYPE is null or sf.surgical is null
            then null
          else 0
        end as ElectiveSurgery

      -- age group
      , case
        when ( ( cast(ie.intime as date) - cast(pat.dob as date) ) / 365.242 ) <= 1 then 'neonate'
        when ( ( cast(ie.intime as date) - cast(pat.dob as date) ) / 365.242 ) <= 15 then 'middle'
        else 'adult' end as ICUSTAY_AGE_GROUP

      -- mortality flags
      , case
          when adm.deathtime between ie.intime and ie.outtime
            then 1
          when adm.deathtime <= ie.intime -- sometimes there are typographical errors in the death date
            then 1
          when adm.dischtime <= ie.outtime and adm.discharge_location = 'DEAD/EXPIRED'
            then 1
          else 0 end
        as ICUSTAY_EXPIRE_FLAG
      , adm.hospital_expire_flag
from icustays ie
inner join admissions adm
  on ie.hadm_id = adm.hadm_id
inner join patients pat
  on ie.subject_id = pat.subject_id
left join surgflag sf
  on ie.icustay_id = sf.icustay_id
-- join to custom tables to get more data....
left join gcsfirstday gcs
  on ie.icustay_id = gcs.icustay_id
left join vitalsfirstday vital
  on ie.icustay_id = vital.icustay_id
left join uofirstday uo
  on ie.icustay_id = uo.icustay_id
left join ventfirstday vent
  on ie.icustay_id = vent.icustay_id
)
, scorecomp as
(
select co.subject_id, co.hadm_id, co.icustay_id
, co.ICUSTAY_AGE_GROUP
, co.icustay_expire_flag
, co.hospital_expire_flag

-- Below code calculates the component scores needed for OASIS
, case when preiculos is null then null
     when preiculos < '0 0:10:12' then 5
     when preiculos < '0 4:57:00' then 3
     when preiculos < '1 0:00:00' then 0
     when preiculos < '12 23:48:00' then 1
     else 2 end as preiculos_score
,  case when age is null then null
      when age < 24 then 0
      when age <= 53 then 3
      when age <= 77 then 6
      when age <= 89 then 9
      when age >= 90 then 7
      else 0 end as age_score
,  case when mingcs is null then null
      when mingcs <= 7 then 10
      when mingcs < 14 then 4
      when mingcs = 14 then 3
      else 0 end as gcs_score
,  case when heartrate_max is null then null
      when heartrate_max > 125 then 6
      when heartrate_min < 33 then 4
      when heartrate_max >= 107 and heartrate_max <= 125 then 3
      when heartrate_max >= 89 and heartrate_max <= 106 then 1
      else 0 end as heartrate_score
,  case when meanbp_min is null then null
      when meanbp_min < 20.65 then 4
      when meanbp_min < 51 then 3
      when meanbp_max > 143.44 then 3
      when meanbp_min >= 51 and meanbp_min < 61.33 then 2
      else 0 end as meanbp_score
,  case when resprate_min is null then null
      when resprate_min <   6 then 10
      when resprate_max >  44 then  9
      when resprate_max >  30 then  6
      when resprate_max >  22 then  1
      when resprate_min <  13 then 1 else 0
      end as resprate_score
,  case when tempc_max is null then null
      when tempc_max > 39.88 then 6
      when tempc_min >= 33.22 and tempc_min <= 35.93 then 4
      when tempc_max >= 33.22 and tempc_max <= 35.93 then 4
      when tempc_min < 33.22 then 3
      when tempc_min > 35.93 and tempc_min <= 36.39 then 2
      when tempc_max >= 36.89 and tempc_max <= 39.88 then 2
      else 0 end as temp_score
,  case when UrineOutput is null then null
      when UrineOutput < 671.09 then 10
      when UrineOutput > 6896.80 then 8
      when UrineOutput >= 671.09
       and UrineOutput <= 1426.99 then 5
      when UrineOutput >= 1427.00
       and UrineOutput <= 2544.14 then 1
      else 0 end as UrineOutput_score
,  case when mechvent is null then null
      when mechvent = 1 then 9
      else 0 end as mechvent_score
,  case when ElectiveSurgery is null then null
      when ElectiveSurgery = 1 then 0
      else 6 end as electivesurgery_score


-- The below code gives the component associated with each score
-- This is not needed to calculate OASIS, but provided for user convenience.
-- If both the min/max are in the normal range (score of 0), then the average value is stored.
, preiculos
, age
, mingcs as gcs
,  case when heartrate_max is null then null
      when heartrate_max > 125 then heartrate_max
      when heartrate_min < 33 then heartrate_min
      when heartrate_max >= 107 and heartrate_max <= 125 then heartrate_max
      when heartrate_max >= 89 and heartrate_max <= 106 then heartrate_max
      else (heartrate_min+heartrate_max)/2 end as heartrate
,  case when meanbp_min is null then null
      when meanbp_min < 20.65 then meanbp_min
      when meanbp_min < 51 then meanbp_min
      when meanbp_max > 143.44 then meanbp_max
      when meanbp_min >= 51 and meanbp_min < 61.33 then meanbp_min
      else (meanbp_min+meanbp_max)/2 end as meanbp
,  case when resprate_min is null then null
      when resprate_min <   6 then resprate_min
      when resprate_max >  44 then resprate_max
      when resprate_max >  30 then resprate_max
      when resprate_max >  22 then resprate_max
      when resprate_min <  13 then resprate_min
      else (resprate_min+resprate_max)/2 end as resprate
,  case when tempc_max is null then null
      when tempc_max > 39.88 then tempc_max
      when tempc_min >= 33.22 and tempc_min <= 35.93 then tempc_min
      when tempc_max >= 33.22 and tempc_max <= 35.93 then tempc_max
      when tempc_min < 33.22 then tempc_min
      when tempc_min > 35.93 and tempc_min <= 36.39 then tempc_min
      when tempc_max >= 36.89 and tempc_max <= 39.88 then tempc_max
      else (tempc_min+tempc_max)/2 end as temp
,  UrineOutput
,  mechvent
,  ElectiveSurgery
from cohort co
)
, score as
(
select s.*
    , coalesce(age_score,0)
    + coalesce(preiculos_score,0)
    + coalesce(gcs_score,0)
    + coalesce(heartrate_score,0)
    + coalesce(meanbp_score,0)
    + coalesce(resprate_score,0)
    + coalesce(temp_score,0)
    + coalesce(urineoutput_score,0)
    + coalesce(mechvent_score,0)
    + coalesce(electivesurgery_score,0)
    as OASIS
from scorecomp s
)
select
  subject_id, hadm_id, icustay_id
  , ICUSTAY_AGE_GROUP
  , hospital_expire_flag
  , icustay_expire_flag
  , OASIS
  -- Calculate the probability of in-hospital mortality
  , 1 / (1 + exp(- (-6.1746 + 0.1275*(OASIS) ))) as OASIS_PROB
  , age, age_score
  , preiculos, preiculos_score
  , gcs, gcs_score
  , heartrate, heartrate_score
  , meanbp, meanbp_score
  , resprate, resprate_score
  , temp, temp_score
  , urineoutput, UrineOutput_score
  , mechvent, mechvent_score
  , electivesurgery, electivesurgery_score
from score
order by icustay_id;
