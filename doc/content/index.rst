.. toctree::
    :maxdepth: 2
    :caption: Contents

Sacrifice to Sphinx
===================

Overview
========
.. This is the start of the documentation and aimed in part at a non technical audience.
   Keep your sentences short. This aides in understanding as well as translation. 

Summary
-------
.. A very short description of the package, about 1 or 2 sentences. This can be the same info that is visible in the OTOBO package manager. 

Print Tickets with advanced formatting, including images.

Usage
------------

Following installation, this package is active and usable right away.

Tickets and their articles are now printed in their original styling, including content such as inline images. 

By default, the printing is handled by the client browser. It can be configured to use a headless Chrome browser on the server side instead. The necessary configuration steps are explained in the :ref:`Setup` section below.

The logo to be printed at the top of the page can be specified with : :ref:`Ticket::Frontend::AgentTicketPrint###PrintLogoFile`

A complete list of options can be found in the :ref:`Ticket::Frontend::AgentTicketPrint###Configuration Reference`

Setup
-----

No further configuration is required for the package to work. However, if you want to use the server side printing feature, please follow the steps below.

For server side printing with HTML styles and images, it is required that a headless Google Chrome browser is running on the server.

In in docker, it is necessary to change the container's security configuration. For this purpose, a modified seccomp profile is required. A version with the additional permissions is part of the package download, but regular updating to current docker versions is required. Please put the file ``scripts/docker-compose/seccomp_profile.json`` in the directory where the docker-compose file of the OTOBO installation is located, e.g. to ``/opt/otobo-docker/docker-compose/seccomp_profile.json``.

After that, please edit the file ``/opt/otobo-docker/docker-compose/otobo-base.yml`` and insert the following two lines ( *without the plus signs* ), directly below the line ``command: web``:

.. code-block:: diff

     # The HTTP port might be specified in a docker-compose extension file, e.g. docker-compose/otobo-override-http.yml.
     # For HTTPS no HTTP port is exposed.
     #ports:
     #    - "80:5000"
     volumes:
       - opt_otobo:/opt/otobo
     command: web
    +security_opt:
    +  - seccomp:seccomp_profile.json
     healthcheck:
       test: curl -s -f http://localhost:5000/robots.txt

Following this, please restart the containers by executing ``docker-compose down``, followed by ``docker compose up -d``.

System requirements
-------------------

Framework
^^^^^^^^^
.. What version of OTOBO was this package developed for?

OTOBO 11.0.x

Packages
^^^^^^^^
.. Which packages does this one depend on? Only list direct dependencies. Keep in mind that order can be important and include version numbers.

.. Package Name x.x.x

\-

Third-party software
^^^^^^^^^^^^^^^^^^^^
\-

Configuration Reference
-----------------------

Core::Ticket
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

TicketPrint::Browser
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Select the browser for rendering ticket print previews. For Headless Chrome to work, GoogleChrome::Bin must be configured.

Frontend::Agent::View::TicketPrint
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Ticket::Frontend::AgentTicketPrint###PrintLogoFile
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Specifies the file for the logo in the page header encoded to base64 (700 x 100 pixel).

Ticket::Frontend::AgentTicketPrint###Widgets###0100-TicketInformation
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Printing information usually visible in the Ticket Information Widget for the Zoom View sidebar.

Ticket::Frontend::AgentTicketPrint###Widgets###0200-CustomerInformation
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Printing information usually visible in the Customer Information Widget for the Zoom View sidebar.

Ticket::Frontend::CustomerTicketPrint###PrintLogoFile
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Specifies the file for the logo in the page header encoded to base64 (700 x 100 pixel).

Frontend::Customer::View::TicketPrint
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Ticket::Frontend::CustomerTicketPrint###AttributesView
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Shows the enabled ticket attributes in the customer interface (0 = Disabled and 1 = Enabled).

Ticket::Frontend::CustomerTicketPrint###TicketInformation
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Printing information usually visible in the Customer Information Widget for the Zoom View sidebar.

About
=======

Contact
-------
| Rother OSS GmbH
| Email: hello@otobo.io
| Web: https://otobo.io

Version
-------
Author: |doc-vendor| / Version: |doc-version| / Date of release: |doc-datestamp|
