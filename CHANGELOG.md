Changelog
=========

2022-09-20 2.1.0:

- Allow installation in a custom schema (Julien Rouhaud)
- debian packaging improvements (Chrstoph Berg)
- Make the extension compatible with EDB fork of postgres (Julien Rouhaud, per
  report from github user manishnew09 and help from Thomas Reiss)
- various regression testss improvements (Julien Rouhaud)

2020-10-02 2.0.1:
------------------

  - Fix handling of dropped pg_db_role_setting entries.  Thanks to Adrien
    Nayrat for the report.

2019-09-05 2.0.0:
------------------

  - Add support for remote snapshot mode that will be available with powa 4
    (thanks to github user Ikrar-k for testing and bug reporting)
  - Add pg_track_reboot_log function

2018-07-15 version 1.0.1:
-------------------------

**Bug fixes**:

  - Fix issue leading to duplicated role settings changes when several
    roles exists (Adrien Nayrat).

2015-12-06 version 1.0.0:
-------------------------

  - First version of pg_track_settings.
