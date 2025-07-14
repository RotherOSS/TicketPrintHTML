# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::Modules::CustomerTicketPrint;

use strict;
use warnings;
use utf8;

our $ObjectManagerDisabled = 1;

# core modules

# CPAN modules
use PDF::API2 qw(open);

# OTOBO modules
use Kernel::System::VariableCheck qw(:all);
use Kernel::Language              qw(Translatable);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = bless {%Param}, $Type;

    # set debug
    $Self->{Debug} = 0;

    # get needed objects
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');

    $Self->{ArticleID} = $ParamObject->GetParam( Param => 'ArticleID' ) || '';

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # get layout object
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    # check needed stuff
    if ( !$Self->{TicketID} ) {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('No TicketID is given!'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    # get needed objects
    my $TicketObject   = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ConfigObject   = $Kernel::OM->Get('Kernel::Config');
    my $DateTimeObject = $Kernel::OM->Create('Kernel::System::DateTime');
    my $MainObject     = $Kernel::OM->Get('Kernel::System::Main');
    my $FileTempObject = $Kernel::OM->Get('Kernel::System::FileTemp');

    # check permissions
    my $Access = $TicketObject->TicketCustomerPermission(
        Type     => 'ro',
        TicketID => $Self->{TicketID},
        UserID   => $Self->{UserID},
    );

    # No permission, do not show ticket.
    return $LayoutObject->CustomerNoPermission( WithHeader => 'no' ) if !$Access;

    # Get ACL restrictions.
    my %PossibleActions = ( 1 => $Self->{Action} );

    my $ACL = $TicketObject->TicketAcl(
        Data           => \%PossibleActions,
        Action         => $Self->{Action},
        TicketID       => $Self->{TicketID},
        ReturnType     => 'Action',
        ReturnSubType  => '-',
        CustomerUserID => $Self->{UserID},
    );

    my %AclAction = %PossibleActions;

    # check if ACL restrictions exist
    my %AclActionLookup = reverse %AclAction;

    # show error screen if ACL prohibits this action
    if ( !$AclActionLookup{ $Self->{Action} } ) {
        return $LayoutObject->CustomerNoPermission( WithHeader => 'no' );
    }

    # get ticket attributes
    my %Ticket = $TicketObject->TicketGet(
        TicketID      => $Self->{TicketID},
        DynamicFields => 1,
    );

    my $HTML = $Self->_CreateHTMLContent(
        Ticket => \%Ticket,
    );

    my $HTMLFileDirectory = $FileTempObject->TempDir();

    my ($FileHandle, $HTMLFilePath) = $FileTempObject->TempFile(
        Suffix => '.html',
    );
    close($FileHandle);

    $MainObject->FileWrite(
        Location    => $HTMLFilePath,
        Content     => \$HTML,
    );

    my $PDFFilePath = $Self->_PrintPDF(
        FileTempObject   => $FileTempObject,
        HTMLFilePath     => $HTMLFilePath,
    );

    # check if we got a result
    if (!$PDFFilePath) {

        # error likely stems from chrome path not being configured and was logged earlier in this case
        return $LayoutObject->ErrorScreen(
            Message => Translatable('PDF cannot be generated!'),
            Comment => Translatable('Please contact the administrator and check the log file for more information.'),
        );
    }

    # check if file exists
    if ( !-e $PDFFilePath ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "PDF file '$PDFFilePath' does not exist!",
        );
        return $LayoutObject->ErrorScreen(
            Message => Translatable('PDF cannot be generated!'),
            Comment => Translatable('Please contact the administrator and check the log file for more information.'),
        );
    }

    # return the document as string
    my $PDF = PDF::API2->open($PDFFilePath);

    my $PDFString = $PDF->stringify();
    $PDF->end();

    # assemble filename
    if ( $Self->{UserTimeZone} ) {
        $DateTimeObject->ToTimeZone( TimeZone => $Self->{UserTimeZone} );
    }
    my $Filename = 'Ticket_' . $Ticket{TicketNumber} . '_';
    $Filename .= $DateTimeObject->Format( Format => '%Y-%m-%d_%H_%M' );
    $Filename .= '.pdf';

    my $CleanedFilename = $Kernel::OM->Get('Kernel::System::Main')->FilenameCleanUp(
        Filename => $Filename,
        Type     => 'Attachment',
    );

    return $LayoutObject->Attachment(
        Filename    => $CleanedFilename,
        ContentType => "application/pdf",
        Content     => $PDFString,
        Type        => 'inline',
    );
}

sub _CreateHTMLContent {
    my ( $Self, %Param ) = @_;

    # Check needed stuff.
    for my $Needed (qw(Ticket)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    my %Ticket = %{ $Param{Ticket} };

    my $LayoutObject  = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $ConfigObject  = $Kernel::OM->Get('Kernel::Config');
    my $MainObject    = $Kernel::OM->Get('Kernel::System::Main');

    my $DisplaySettings = $ConfigObject->Get('Ticket::Frontend::CustomerTicketPrint') // {};

    my $Order = $Self->{ArticleSort} eq 'reverse' ? 'DESC' : 'ASC';

    # Get all articles.
    my @ArticleBox = $ArticleObject->ArticleList(
        TicketID             => $Self->{TicketID},
        IsVisibleForCustomer => 1,
    );

    if ( $Order eq 'DESC' ) {
        @ArticleBox = reverse @ArticleBox;
    }

    # show only specified article
    if ( $Self->{ArticleID}) {
        ARTICLE:
        for my $Article (@ArticleBox) {
            next ARTICLE if !$Article->{ArticleID};
            next ARTICLE if $Self->{ArticleID} ne $Article->{ArticleID};

            @ArticleBox = ($Article);

            last ARTICLE;
        }
    }

    # age design
    $Ticket{Age} = $LayoutObject->CustomerAge(
        Age   => $Ticket{Age},
        Space => ' '
    );

    my $TicketInfoHTML = $DisplaySettings->{TicketInformation} ? $Self->_RenderTicketInfo( %Ticket ) : '';

    # set display options
    $Param{Hook} = $ConfigObject->Get('Ticket::Hook') || 'Ticket#';

    # number of articles
    $Param{ArticleCount} = scalar @ArticleBox;

    # print logo
    $Param{PDFLogo} = '';
    if ( $DisplaySettings->{PrintLogoFile} ) {
        $Param{PDFLogo} = $DisplaySettings->{PrintLogoFile};
    }

    $LayoutObject->Block(
        Name => 'Header',
        Data => { %Param, %Ticket },
    );

    my @ArticleIDs;
    my $ArticleWidgetsHTML = '';

    ARTICLE:
    for my $Article (@ArticleBox) {

        $ArticleWidgetsHTML .= $Self->_ArticleRender(
            TicketID               => $Ticket{TicketID},
            ArticleID              => $Article->{ArticleID},
            UserID                 => $Self->{UserID},
        );

        push @ArticleIDs, $Article->{ArticleID};
    }

    $Param{ArticleItems} = $ArticleWidgetsHTML;

    # show no articles block if ticket does not contain articles
    if ( !@ArticleBox ) {
        $LayoutObject->Block(
            Name => 'HintNoArticles',
        );
    }

    # return output
    return $LayoutObject->Output(
        TemplateFile => 'CustomerTicketPrint',
        Data         => {
            %Param,
            %Ticket,
            TicketInfoHTML => $TicketInfoHTML,
        },
    );
}

=head2 _ArticleRender()

Returns article html.

Implementation based on
Kernel::Output::HTML::TicketZoom::Agent::MIMEBase->ArticleRender() and
Kernel::Modules::AgentTicketArticleContent->Run()

Result:
    $HTML = "<div>...</div>";

=cut

sub _ArticleRender {
    my ( $Self, %Param ) = @_;

    # Check needed stuff.
    for my $Needed (qw(TicketID ArticleID)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    $Param{ShowBrowserLinkMessage} = 0;

    my $LayoutObject      = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject      = $Kernel::OM->Get('Kernel::Config');
    my $ArticleBaseObject = $Kernel::OM->Get('Kernel::Output::HTML::TicketZoom::Customer::Base');

# First part is based on Kernel::Output::HTML::TicketZoom::Agent::MIMEBase->ArticleRender()

    # Get article data.
    my $ArticleBackendObject = $Kernel::OM->Get('Kernel::System::Ticket::Article')->BackendForArticle(%Param);

    my %Article = $ArticleBackendObject->ArticleGet(
        %Param,
        RealNames => 1,
    );
    if ( !%Article ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Article not found (ArticleID=$Param{ArticleID})!"
        );
        return;
    }

    # Get channel specific fields
    my %ArticleFields = $LayoutObject->ArticleFields(%Param);

    # Get dynamic fields and accounted time
    my %ArticleMetaFields = $ArticleBaseObject->ArticleMetaFields(
        %Param,
        DisplaySettingsSource => 'Ticket::Frontend::CustomerTicketPrint'
    );

    # Show created by string, if creator is different from admin user.
    if ( $Article{CreateBy} > 1 ) {
        $Article{CreateByUser} = $Kernel::OM->Get('Kernel::System::User')->UserName( UserID => $Article{CreateBy} );
    }

    my %CommunicationChannel = $Kernel::OM->Get('Kernel::System::CommunicationChannel')->ChannelGet(
        ChannelID => $Article{CommunicationChannelID},
    );

# Implementation based on Kernel::Modules::AgentTicketArticleContent from here on.

    my $ArticleStorage = $ConfigObject->Get('Ticket::Article::Backend::MIMEBase::ArticleStorage');

    my $RichTextEnabled = $ConfigObject->Get('Ticket::Frontend::ZoomRichTextForce')
        || $LayoutObject->{BrowserRichText}
        || 0;

    # Show HTML if RichText is enabled and HTML attachment isn't missing.
    my $ShowHTML = $RichTextEnabled;

    my $HTMLBodyAttachID = $Kernel::OM->Get('Kernel::Output::HTML::Article::MIMEBase')->HTMLBodyAttachmentIDGet(
        ArticleID           => $Article{ArticleID},
        TicketID            => $Article{TicketID},
        UserID              => $Self->{UserID},
    );
    if ( $ShowHTML && !$HTMLBodyAttachID ) {
        $ShowHTML = 0;
    }

    my $ArticleContent;
    if ( $ShowHTML ) {
        $ArticleContent = $LayoutObject->ArticlePreview(
            ArticleID           => $Article{ArticleID},
            TicketID            => $Article{TicketID},
            ShowDeletedArticles => 0,
            ArticleStorage      => $ArticleStorage,
            SourceArticleID     => $Self->{SourceArticleID},
            ResultType          => 'html',
        );

    }
    else {
        $ArticleContent = $LayoutObject->ArticlePreview(
            ArticleID           => $Article{ArticleID},
            TicketID            => $Article{TicketID},
            ShowDeletedArticles => 0,
            ArticleStorage      => $ArticleStorage,
            SourceArticleID     => $Self->{SourceArticleID},
            ResultType          => 'plain',
        );

        # html quoting
        $ArticleContent = $LayoutObject->Ascii2Html(
            NewLine        => $ConfigObject->Get('DefaultViewNewLine'),
            Text           => $ArticleContent,
            VMax           => $ConfigObject->Get('DefaultViewLines') || 5000,
            HTMLResultMode => 1,
            LinkFeature    => 1,
        );
    }

    if ( !$ArticleContent ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Message  => 'No such article!',
            Priority => 'error',
        );

        return $LayoutObject->ErrorScreen();
    }

    # generate base url
    my $URL;

    if ( !$Self->{VersionView} ) {
        $URL = 'Action=AgentTicketAttachment;Subaction=HTMLView'
            . ";TicketID=$Article{TicketID};ArticleID=$Article{ArticleID};FileID=";
    }
    else {
        $URL = 'Action=AgentTicketAttachment;Subaction=HTMLView'
            . ";TicketID=$Article{TicketID};ArticleID=$Article{ArticleID};VersionView=1;SourceArticleID=$Self->{SourceArticleID};FileID=";
    }

    # replace links to inline images in html content
    my %AtmBox = $ArticleBackendObject->ArticleAttachmentIndex(
        ArticleID       => $Article{ArticleID},
        SourceArticleID => $Self->{SourceArticleID},
    );

    # Do not load external images if 'BlockLoadingRemoteContent' is enabled.
    my $LoadExternalImages = 1;
    if ( $ConfigObject->Get('Ticket::Frontend::BlockLoadingRemoteContent') ) {
        $LoadExternalImages = 0;
    }

    my $SenderInitials  = $LayoutObject->UserInitialsGet(
        Fullname => $Article{FromRealname},
    );

    my $SenderImage => $Kernel::OM->Get('Kernel::Output::HTML::TicketZoom::Agent::Base')->_ArticleSenderImage(
        Sender => $Article{From},
        UserID => $Self->{UserID},
    );

    $ArticleContent =~ s{
        (=|"|')cid:(.*?)("|'|>|\/>|\s)
    }
    {
        my $Start= $1;
        my $ContentID = $2;
        my $End = $3;
        my $Content = '';

        # improve html quality
        if ( $Start ne '"' && $Start ne '\'' ) {
            $Start .= '"';
        }
        if ( $End ne '"' && $End ne '\'' ) {
            $End = '"' . $End;
        }

        # find matching attachment and replace it with base64 of image
        ATTACHMENT_ID:
        for my $AttachmentID ( sort keys %AtmBox ) {
            next ATTACHMENT_ID if lc $AtmBox{$AttachmentID}{ContentID} ne lc "<$ContentID>";

            my %Attachment = $ArticleBackendObject->ArticleAttachment(
                ArticleID => $Article{ArticleID},
                FileID    => $AttachmentID,
            );

            my ( $ContentType ) = %Attachment && $Attachment{ContentType} ? ( $Attachment{ContentType} =~ /^([^;]+)/ ) : ();

            $Content = $ContentType && $Attachment{Content} ? "data:$ContentType;base64," . MIME::Base64::encode_base64( $Attachment{Content} ) : "";

            last ATTACHMENT_ID;
        }

        # return new runtime url
        $Start . $Content . $End;
    }egxi;

    # inline images using Content-Location as identifier instead of Content-ID even RFC2557
    # http://www.ietf.org/rfc/rfc2557.txt
    # find matching attachment and replace it with runtlime url to image
    ATTACHMENT:
    for my $AttachmentID ( sort keys %AtmBox ) {
        next ATTACHMENT if !$AtmBox{$AttachmentID}{ContentID};

        # content id cleanup
        $AtmBox{$AttachmentID}{ContentID} =~ s/^<//;
        $AtmBox{$AttachmentID}{ContentID} =~ s/>$//;

        next ATTACHMENT if !$AtmBox{$AttachmentID}{ContentID};

        $Article{Body} =~ s{
            (=|"|')(\Q$AtmBox{$AttachmentID}{ContentID}\E)("|'|>|\/>|\s)
        }
        {
            my $Start= $1;
            my $ContentID = $2;
            my $End = $3;

            my %Attachment = $ArticleBackendObject->ArticleAttachment(
                ArticleID => $Article{ArticleID},
                FileID    => $AttachmentID,
            );

            my ( $ContentType ) = %Attachment && $Attachment{ContentType} ? ( $Attachment{ContentType} =~ /^([^;]+)/ ) : ();

            my $Content = $ContentType && $Attachment{Content} ? "data:$ContentType;base64," . MIME::Base64::encode_base64( $Attachment{Content} ) : "";
            $Start . $Content . $End;
        }egxi;
    }

    my %Data = (
        Content            => $ArticleContent,
        ContentAlternative => '',
        ContentID          => '',
        ContentType        => 'text/html; charset="utf-8"',
        Disposition        => 'inline',
    );

    # if there is unexpectedly pgp decrypted content in the html email (OE),
    # we will use the article body (plain text) from the database as fall back
    # see bug#9672
    if (
        $Data{Content} =~ m{
        ^ .* -----BEGIN [ ] PGP [ ] MESSAGE-----  .* $      # grep PGP begin tag
        .+                                                  # PGP parts may be nested in html
        ^ .* -----END [ ] PGP [ ] MESSAGE-----  .* $        # grep PGP end tag
    }xms
        )
    {

        # html quoting
        $Article{Body} = $LayoutObject->Ascii2Html(
            NewLine        => $ConfigObject->Get('DefaultViewNewLine'),
            Text           => $Article{Body},
            VMax           => $ConfigObject->Get('DefaultViewLines') || 5000,
            HTMLResultMode => 1,
            LinkFeature    => 1,
        );

        # use the article body as content, because pgp was definitly decrypted if possible
        $Data{Content} = $Article{Body};
    }

    $ArticleContent = $Data{Content};

    # extract styles from articles
    my @Styles;
    $ArticleContent =~ s/(<style[^<>]*>)(.*?)(<\/style>)/push @Styles, [$1, $2, $3]; ""/gse;
    my $CombinedStyles = join("\n", map { $_->[1] } @Styles);

    #remove meta tag
    $ArticleContent =~ s/<meta[^<>]*>//g;

    return $LayoutObject->Output(
        TemplateFile => 'TicketPrintHTML/MIMEBase',
        Data         => {
            %Article,
            ArticleFields        => \%ArticleFields,
            CommunicationChannel => $CommunicationChannel{DisplayName},
            ArticleMetaFields    => \%ArticleMetaFields,
            SenderImage          => $SenderImage,
            SenderInitials       => $SenderInitials,
            HTML                 => $ArticleContent,
            Styles               => $CombinedStyles
        },
    )
}

=head2 _PrintPDF()

Generates a PDF from an HTML file using Google Chrome in headless mode.

This function requires the path to the HTML file to be specified in the
C<HTMLFilePath> parameter. It retrieves the path to the Google Chrome binary
from the configuration and executes Chrome with specific flags to convert the
HTML file to a PDF.

Returns the path of the resulting .pdf file.

=cut

sub _PrintPDF {
    my ( $Self, %Param ) = @_;

    # Check needed stuff.
    # FileTempObject must be passed to prevent premature file deletion
    for my $Needed (qw(HTMLFilePath FileTempObject)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $FileTempObject = $Param{'FileTempObject'};

    my $HTMLFilePath = $Param{HTMLFilePath};
    my ($FileHandle, $PDFFilePath) = $FileTempObject->TempFile(
        Suffix => '.pdf'
    );
    $FileHandle->close();

    my $ChromePath = $ConfigObject->Get('GoogleChrome::Bin');
    if ( !$ChromePath ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Google Chrome path not configured!",
        );
        return;
    }

    my $CommandResult = `'$ChromePath' --no-sandbox --aggressive-cache-discard --headless --print-to-pdf='$PDFFilePath' --no-pdf-header-footer --virtual-time-budget=25000 '$HTMLFilePath' 2>&1`;
    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message  => "Chrome PDF Print: " . $CommandResult,
    );

    return $PDFFilePath;
}

sub _RenderTicketInfo {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    my $Config = $ConfigObject->Get("Ticket::Frontend::CustomerTicketPrint") // {};

    # ticket type
    if ( $ConfigObject->Get('Ticket::Type') && $Config->{AttributesView}->{Type} ) {

        my %Type = $Kernel::OM->Get('Kernel::System::Type')->TypeGet(
            Name => $Param{Type},
        );

        $LayoutObject->Block(
            Name => 'Type',
            Data => {
                Valid => $Type{ValidID},
                %Param,
            }
        );
    }

    # ticket service
    if (
        $Param{Service}
        &&
        $ConfigObject->Get('Ticket::Service')
        && $Config->{AttributesView}->{Service}
        )
    {
        $LayoutObject->Block(
            Name => 'Service',
            Data => \%Param,
        );
        if (
            $Param{SLA}
            && $ConfigObject->Get('Ticket::Service')
            && $Config->{AttributesView}->{SLA}
            )
        {
            $LayoutObject->Block(
                Name => 'SLA',
                Data => \%Param,
            );
        }
    }

    # ticket state
    if ( $Config->{AttributesView}->{State} ) {
        $LayoutObject->Block(
            Name => 'State',
            Data => \%Param,
        );
    }

    # ticket priority
    if ( $Config->{AttributesView}->{Priority} ) {
        $LayoutObject->Block(
            Name => 'Priority',
            Data => \%Param,
        );
    }

    # ticket queue
    if ( $Config->{AttributesView}->{Queue} ) {
        $LayoutObject->Block(
            Name => 'Queue',
            Data => \%Param,
        );
    }

    my $AgentUserObject = $Kernel::OM->Get('Kernel::System::User');

    # ticket owner
    if ( $Config->{AttributesView}->{Owner} ) {
        my $OwnerName = $AgentUserObject->UserName(
            UserID => $Param{OwnerID},
        );
        $LayoutObject->Block(
            Name => 'Owner',
            Data => { OwnerName => $OwnerName },
        );
    }

    # ticket responsible
    if (
        $ConfigObject->Get('Ticket::Responsible')
        &&
        $Config->{AttributesView}->{Responsible}
        )
    {
        my $ResponsibleName = $AgentUserObject->UserName(
            UserID => $Param{ResponsibleID},
        );
        $LayoutObject->Block(
            Name => 'Responsible',
            Data => {
                ResponsibleName => $ResponsibleName,
            },
        );
    }

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    # check if ticket is normal or process ticket
    my $IsProcessTicket = $TicketObject->TicketCheckForProcessType(
        'TicketID' => $Self->{TicketID},
    );

    # show process widget  and activity dialogs on process tickets
    if ($IsProcessTicket) {

        # get the DF where the ProcessEntityID is stored
        my $ProcessEntityIDField = 'DynamicField_'
            . $ConfigObject->Get("Process::DynamicFieldProcessManagementProcessID");

        # get the DF where the AtivityEntityID is stored
        my $ActivityEntityIDField = 'DynamicField_'
            . $ConfigObject->Get("Process::DynamicFieldProcessManagementActivityID");

        # create additional objects for process management
        my $ActivityObject       = $Kernel::OM->Get('Kernel::System::ProcessManagement::Activity');
        my $ActivityDialogObject = $Kernel::OM->Get('Kernel::System::ProcessManagement::ActivityDialog');
        my $ProcessObject        = $Kernel::OM->Get('Kernel::System::ProcessManagement::Process');
        my $ProcessData          = $ProcessObject->ProcessGet(
            ProcessEntityID => $Param{$ProcessEntityIDField},
        );

        my $ActivityData = $ActivityObject->ActivityGet(
            Interface        => 'CustomerInterface',
            ActivityEntityID => $Param{$ActivityEntityIDField},
        );

        # output process information in the sidebar
        $LayoutObject->Block(
            Name => 'ProcessData',
            Data => {
                Process  => $ProcessData->{Name}  || '',
                Activity => $ActivityData->{Name} || '',
            },
        );
    }

    my $DynamicFieldObject = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $BackendObject      = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

    # get the dynamic fields for ticket object
    my $DynamicField = $DynamicFieldObject->DynamicFieldListGet(
        Valid       => 1,
        ObjectType  => ['Ticket'],
        FieldFilter => $Config->{DynamicField} || {},
    );

    # cycle trough the activated Dynamic Fields for ticket object
    DYNAMICFIELD:
    for my $DynamicFieldConfig ( @{$DynamicField} ) {
        next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);

        # skip the dynamic field if is not designed for customer interface
        my $IsCustomerInterfaceCapable = $BackendObject->HasBehavior(
            DynamicFieldConfig => $DynamicFieldConfig,
            Behavior           => 'IsCustomerInterfaceCapable',
        );
        next DYNAMICFIELD if !$IsCustomerInterfaceCapable;

        my $Value = $BackendObject->ValueGet(
            DynamicFieldConfig => $DynamicFieldConfig,
            ObjectID           => $Param{TicketID},
        );

        next DYNAMICFIELD if !defined $Value;
        next DYNAMICFIELD if $Value eq "";

        # get print string for this dynamic field
        my $ValueStrg = $BackendObject->DisplayValueRender(
            DynamicFieldConfig => $DynamicFieldConfig,
            Value              => $Value,
#            ValueMaxChars      => 100,
            HTMLOutput         => 0,
            LayoutObject       => $LayoutObject,
        );

        my $Label = $DynamicFieldConfig->{Label};

        $LayoutObject->Block(
            Name => 'TicketDynamicField',
            Data => {
                Label => $Label,
            },
        );

        if ( $DynamicFieldConfig->{Config}->{Link} ) {
            $LayoutObject->Block(
                Name => 'TicketDynamicFieldLink',
                Data => {
                    Value                       => $ValueStrg->{Value},
                    Title                       => $ValueStrg->{Title},
                    Link                        => $DynamicFieldConfig->{Config}->{Link},
                    LinkPreview                 => $DynamicFieldConfig->{Config}->{LinkPreview},
                    $DynamicFieldConfig->{Name} => $ValueStrg->{Value},
                },
            );
        }
        else {
            $LayoutObject->Block(
                Name => 'TicketDynamicFieldPlain',
                Data => {
                    Value => $ValueStrg->{Value},
                    Title => $ValueStrg->{Title},
                },
            );
        }
    }

    return $LayoutObject->Output(
        TemplateFile => 'CustomerTicketZoom/TicketInfo',
        Data         => {},
    );
}

1;
