begin;

-- Remove the unnecessary date of birth field from the payroll employee register.
alter table charm.payroll_employees drop column if exists date_of_birth;

notify pgrst,'reload schema';
commit;