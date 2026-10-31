# models

The model bundle built on the Mac by `make bundle` (`pipeline/bundle.py`): the client prediction engine's
tables fitted from the lake, the delay-alert model and the arrival model's card. The hourly site build installs
it over its own fit when it is fresh; the app reads the same files from the published site.
