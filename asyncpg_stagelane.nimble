# Package
version     = "0.1.0"
author      = "Alex Boisvert"
#original_author  = "Eugene Kabanov"
description = "Asynchronous PostgreSQL driver for Nim (ported to stagelane async runtime)"
license     = "MIT"
# Skip tests directory
skipDirs = @["tests"]
# Deps
requires "nim >= 2.2.0"
requires "db_connector"
requires "malebolgia >= 1.3.2"
requires "https://github.com/ghazalialshafi/stagelane#head"

