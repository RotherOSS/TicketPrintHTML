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

# OTOBO modules
use Kernel::System::VariableCheck qw(:all);
use Kernel::Language              qw(Translatable);

# CPAN modules
use PDF::API2 qw(open);

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

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $TicketObject  = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $FileTempObject = $Kernel::OM->Get('Kernel::System::FileTemp');
    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

    my $DateTimeObject  = $Kernel::OM->Create('Kernel::System::DateTime');

    # Check needed stuff.
    my $message = '';
    if ( !$Self->{TicketID} ) {
        $message = Translatable('Need TicketID!');
    } elsif ( !$Self->{UserCustomerID} ) {
        $message = Translatable('Need CustomerID!');
    }
    if ($message ne '') {
        my $Output = $LayoutObject->CustomerHeader(
            Title => Translatable('Error'),
        );
        $Output .= $LayoutObject->CustomerError(
            Message => $message
        );
        $Output .= $LayoutObject->CustomerFooter();

        return $Output;
    }

    # Check permissions.
    my $Access = $TicketObject->TicketCustomerPermission(
        Type     => 'ro',
        TicketID => $Self->{TicketID},
        UserID   => $Self->{UserID},
    );

    # No permission, do not show ticket.
    return $LayoutObject->CustomerNoPermission( WithHeader => 'yes' ) if !$Access;

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
    my %AclAction = $TicketObject->TicketAclActionData();

    # Check if ACL restrictions exist.
    if ($ACL) {

        my %AclActionLookup = reverse %AclAction;

        # Show error screen if ACL prohibits this action.
        if ( !$AclActionLookup{ $Self->{Action} } ) {
            return $LayoutObject->CustomerNoPermission( WithHeader => 'yes' );
        }
    }

    # Get ticket data.
    my %Ticket = $TicketObject->TicketGet(
        TicketID      => $Self->{TicketID},
        DynamicFields => 0,
    );

    my $HTMLString = $Self->_CreateHTMLContent(
        TicketID => $Self->{TicketID},
        UserID   => $Self->{UserID},
    );

   my $HTMLFileDirectory = $FileTempObject->TempDir();

    my ($FileHandle, $HTMLFilePath) = $FileTempObject->TempFile(
        Suffix => '.html',
    );
    close($FileHandle);

    $MainObject->FileWrite(
        Location    => $HTMLFilePath,
        Content     => \$HTMLString,
    );

    #DEBUG
    $MainObject->FileWrite(
        Location    => './DEBUG.html',
        Content     => \$HTMLString,
    );
    return $HTMLString;

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

    # TODO: REMOVE TEST CODE
    #return '<html><head></head><body><h1>Test PDF Content</h1></body></html>';

    # Check needed params.
    for my $Needed (qw(TicketID UserID)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => "error",
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $LinkObject   = $Kernel::OM->Get('Kernel::System::LinkObject');

    # Get ticket content.
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my %Ticket       = $TicketObject->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 0,
        UserID        => $Param{UserID},
    );

    
    my $Config = $ConfigObject->Get("Ticket::Frontend::CustomerTicketZoom");
    my $DisplaySettings = $ConfigObject->Get("Ticket::Frontend::CustomerTicketPrint");

    # Create Ticket Info Blocks

    $LayoutObject->Block(
        Name => 'InformationWidget',
        Data => {
            WidgetID => 'TicketInformationWidget',
            WidgetTitle => 'Ticket Information',
        },
    );

    $LayoutObject->Block(
        Name => 'InformationWidgetField',
        Data => {
            Label   => "CustomerID",
            Value => $Ticket{CustomerID} || '-'
        },
    );

    $LayoutObject->Block(
        Name => 'InformationWidgetField',
        Data => {
            Label   => 'Age',
            Value => $Ticket{Age} || '-',
        },
    );

    my $CreatedAt = $LayoutObject->{LanguageObject}->FormatTimeString(
        $Ticket{Created},
        'DateFormat',
    );

    $LayoutObject->Block(
        Name => 'InformationWidgetField',
        Data => {
            Label   => 'Created',
            Value => $CreatedAt || '-',
        },
    );

    # Add ticket data, respecting AttributesView configuration for customer interface.
    my @Attributes = qw(
        State Priority Queue Lock CustomerID Owner
    );
    if ( $ConfigObject->Get('Ticket::Responsible') ) {
        push @Attributes, 'Responsible';
    }
    if ( $ConfigObject->Get('Ticket::Type') ) {
        push @Attributes, 'Responsible';
    }
    if ( $ConfigObject->Get('Ticket::Service') ) {
        push @Attributes, 'Service';
        push @Attributes, 'SLA';
    }

    for my $Attribute (@Attributes) {
        if ( $Config->{AttributesView}->{$Attribute} ) {
            $LayoutObject->Block(
                Name => 'InformationWidgetField',
                Data => {
                    Label   => $Attribute,
                    Value   => $Ticket{$Attribute} || '-',
                },
            );
        }
    }

    # Create Customer Info Block if configured.

    if ($ConfigObject->Get('Ticket::Frontend::CustomerTicketPrint')->{CustomerInformation}) {

        # Get customer info.
        my $CustomerUserObject = $Kernel::OM->Get('Kernel::System::CustomerUser');
        my %CustomerData;
        if ( $Ticket{CustomerUserID} ) {
            %CustomerData = $CustomerUserObject->CustomerUserDataGet(
                User => $Ticket{CustomerUserID},
            );
        }
        elsif ( $Ticket{CustomerID} ) {
            %CustomerData = $CustomerUserObject->CustomerUserDataGet(
                CustomerID => $Ticket{CustomerID},
            );
        }

        my $Map = $CustomerData{Config}->{Map};

        # Check if customer company support is enabled.
        if ( $CustomerData{Config}->{CustomerCompanySupport} ) {
            my $Map2 = $CustomerData{CompanyConfig}->{Map};
            if ($Map2) {
                push( @{$Map}, @{$Map2} );
            }
        }

        my @CustomerInfoFields;
        for my $Field ( @{$Map} ) {
            if ( ${$Field}[3] && $CustomerData{ ${$Field}[0] } ) {
                my %PrintableField;
                $PrintableField{Label} = ${$Field}[1];
                $PrintableField{Value} = $CustomerData{ ${$Field}[0] };
                push @CustomerInfoFields, \%PrintableField;
            }
        }

        if ( @CustomerInfoFields ) {

            $LayoutObject->Block(
                Name => 'InformationWidget',
                Data => {
                    WidgetID => 'CustomerInformationWidget',
                    WidgetTitle => 'Customer Information',
                },
            );

            for my $Field (@CustomerInfoFields) {
                $LayoutObject->Block(
                    Name => 'InformationWidgetField',
                    Data => {
                        Label => $Field->{Label} || '-',
                        Value => $Field->{Value} || '-',
                    },
                );
            }
        }
    }

    # Create Dynamic Field Block if configured.

    my $DynamicFieldFilter = $ConfigObject->Get("Ticket::Frontend::CustomerTicketPrint")->{DynamicField};

    # Get the dynamic fields for ticket object.

    my $DynamicFieldList = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldListGet(
        Valid       => 1,
        ObjectType  => ['Ticket'],
        FieldFilter => $DynamicFieldFilter || {},
    );

    $LayoutObject->Block(
        Name => 'InformationWidget',
        Data => {
            WidgetTitle => 'Dynamic Fields',
        }
    );

    $Self->_RenderDynamicFields(
        LayoutObject => $LayoutObject,
        DynamicFields => $DynamicFieldList,
        Ticket => \%Ticket
    );

    #Create Article Blocks

    # Get article list.
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my @ArticleList  = $ArticleObject->ArticleList(
        TicketID => $Ticket{TicketID},
        UserID   => $Param{UserID},
        IsVisibleForCustomer => 1,
    );

    my $Limit = $ConfigObject->Get('PDF::MaxPages');
    my $RichTextEnabled = $LayoutObject->{BrowserRichText} || 0;


    my @ArticleBox = $Self->_ArticleBoxGet(
        ArticleBoxAll => \@ArticleList,
        Limit         => $Limit,
        RichTextEnabled => $RichTextEnabled,
    );

    # make ticket age readable
    $Ticket{Age} = $LayoutObject->CustomerAge(
        Age   => $Ticket{Age},
        Space => ' '
    );

    # Create Article HTML
    my $ArticleWidgetsHTML = '';
    my $ArticleCounter = 1;
    ARTICLE:
    for my $ArticleTmp (@ArticleBox) {
        my %Article = %$ArticleTmp;

        $ArticleWidgetsHTML .= $Self->_RenderArticle(
            Ticket            => \%Ticket,
            Article           => \%Article,
            ArticleNumber => $ArticleCounter,
        );

        #DEBUG
        #$Kernel::OM->Get('Kernel::System::Main')->FileWrite(
        #    Location => './DEBUG_Article_' . $ArticleCounter . '.html',
        #    Content  => \$ArticleWidgetsHTML,
        #);

        $ArticleCounter++;
    }

    if ( $ArticleCounter == 1 ) {
        $LayoutObject->Block(
            Name => 'HintNoArticles',
        );
    } else {
        $LayoutObject->Block(
            Name => 'Articles',
            Data => {
                ArticleWidgetsHTML => $ArticleWidgetsHTML,
            },
        );
    }

    # Get last missing information and finish HTML output.
    
    my $TicketHook = $ConfigObject->Get('Ticket::Hook') || 'Ticket#';

    return $LayoutObject->Output(
        TemplateFile => 'CustomerTicketPrint',
        Data => {
            Hook                => $TicketHook,
            TicketNumber        => $Ticket{TicketNumber},
            Title               => $Ticket{Title},
            PDFLogo             => $DisplaySettings->{PDFLogo} || '',
        },
    );
}

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

sub _ArticleBoxGet {
    my ( $Self, %Param ) = @_;

    # Check needed params.
    for my $Needed (qw(ArticleBoxAll Limit)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => "error",
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    my $ShowHTML = $Param{RichTextEnabled} || 0;

    my @ArticleList = @{ $Param{ArticleBoxAll} };

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $LayoutObject  = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    my $Start = 0;
    my $End = $Param{Limit} - 1;

    my $LastArticleIndex = scalar @ArticleList - 1;
    if ( $LastArticleIndex < $End) {
        $End = $LastArticleIndex
    }

    my @ArticleBox;
    
    for my $Index ($Start .. $End) {
        my $ArticleBackendObject = $ArticleObject->BackendForArticle( 
            %{$Param{ArticleBoxAll}->[$Index]},
        );
        my %Article              = $ArticleBackendObject->ArticleGet(
            %{$Param{ArticleBoxAll}->[$Index]},
            DynamicFields => 0,
        );
        my %Attachments = $ArticleBackendObject->ArticleAttachmentIndex(
            %{$Param{ArticleBoxAll}->[$Index]},
            ExcludePlainText => 1,
            ExcludeHTMLBody  => 1,
            ExcludeInline    => 1,
        );

        # create attachments string.
        my $AttachmentsString = '';
        for my $FileID ( sort keys %Attachments ) {
            my %File     = %{ $Attachments{$FileID} };
            my $Filesize = $LayoutObject->HumanReadableDataSize( Size => $File{FilesizeRaw} );
            $AttachmentsString .= $File{Filename} . ' (' . $Filesize . ")\n";
        }
        $Article{Attachments} = $AttachmentsString;

        push @ArticleBox, \%Article;
    }

    return @ArticleBox;
}

sub _RenderArticle {
    my ( $Self, %Param ) = @_;

    # Check needed params.
    for my $Needed (qw(Ticket Article)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => "error",
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    #TODO:REMOVE TEST CODE
    #return '<div><h3>This is a test article</h3></div>';

    my %Ticket  = %{ $Param{Ticket} };
    my %Article = %{ $Param{Article} };
    my $ArticleNumber = $Param{ArticleNumber} || 0;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $ArticleStorage = $ConfigObject->Get('Ticket::Article::Backend::MIMEBase::ArticleStorage');
    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');
    my $ArticleBackendObject = $Kernel::OM->Get('Kernel::System::Ticket::Article')->BackendForArticle(
        %Article,
    );

    # Display article fields.
    my %AllArticleFields = $LayoutObject->ArticleFields(%Article);
    my @ArticleFields;
    ARTICLE_FIELD:
    for my $ArticleFieldKey (
        sort { $AllArticleFields{$a}->{Prio} <=> $AllArticleFields{$b}->{Prio} }
        keys %AllArticleFields
        )
    {
        my %ArticleField = %{ $AllArticleFields{$ArticleFieldKey} // {} };

        next ARTICLE_FIELD if $ArticleField{HideInCustomerInterface};
        next ARTICLE_FIELD if $ArticleField{HideInTicketPrint};
        next ARTICLE_FIELD if !$ArticleField{Value};

        push @ArticleFields, \%ArticleField;
    }

    my $CreateTime = $LayoutObject->{LanguageObject}->FormatTimeString(
        $Article{CreateTime},
        'DateFormat',
    ),

    # Get dynamic field config
    my $DynamicFieldFilter = $ConfigObject->Get("Ticket::Frontend::CustomerTicketPrint")->{DynamicField};

    # Get the dynamic fields for ticket object.
    my $AllDynamicFields = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldListGet(
        Valid       => 1,
        ObjectType  => ['Article'],
        FieldFilter => $DynamicFieldFilter || {},
    );

    

    # Show HTML if RichText is enabled and HTML attachment isn't missing.
    my $ShowHTML = $LayoutObject->{BrowserRichText} || 0;

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
            ArticleStorage      => $ArticleStorage,
            SourceArticleID     => $Self->{SourceArticleID},
            ResultType          => 'html',
        );

    }
    else {
        $ArticleContent = $LayoutObject->ArticlePreview(
            ArticleID           => $Article{ArticleID},
            TicketID            => $Article{TicketID},
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
        $LogObject->Log(
            Message  => 'No such article!',
            Priority => 'error',
        );

        return $LayoutObject->ErrorScreen();
    }

    my %AttachementList = $ArticleBackendObject->ArticleAttachmentIndex(
        ArticleID       => $Article{ArticleID},
        SourceArticleID => $Self->{SourceArticleID}
    );

    # Do not load external images if 'BlockLoadingRemoteContent' is enabled.
    my $LoadExternalImages = 1;
    if ( $ConfigObject->Get('Ticket::Frontend::BlockLoadingRemoteContent') ) {
        $LoadExternalImages = 0;
    }

    # replace links to inline images with base64 encoded images
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
        for my $AttachmentID ( sort keys %AttachementList ) {
            next ATTACHMENT_ID if lc $AttachementList{$AttachmentID}{ContentID} ne lc "<$ContentID>";

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
    for my $AttachmentID ( sort keys %AttachementList ) {
        next ATTACHMENT if !$AttachementList{$AttachmentID}{ContentID};

        # content id cleanup
        $AttachementList{$AttachmentID}{ContentID} =~ s/^<//;
        $AttachementList{$AttachmentID}{ContentID} =~ s/>$//;

        next ATTACHMENT if !$AttachementList{$AttachmentID}{ContentID};

        $Article{Body} =~ s{
            (=|"|')(\Q$AttachementList{$AttachmentID}{ContentID}\E)("|'|>|\/>|\s)
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

    #DEBUG
    #$Kernel::OM->Get('Kernel::System::Main')->FileWrite(
    #    Location => './DEBUG_Article_' . $ArticleNumber . '_Content.html',
    #    Content  => \$ArticleContent,
    #);

    return $LayoutObject->Output(
        TemplateFile => 'TicketPrintHTML/CustomerMIMEBase',
        Data         => {
            ArticleFields        => \@ArticleFields,
            ArticleContent       => $ArticleContent,
            Styles               => $CombinedStyles,
            ArticleNumber        => $ArticleNumber,
            SenderType           => $Article{SenderType} || '-',
            CreateTime           => $CreateTime,
        },
    )
}

sub _RenderDynamicFields {
    my ( $Self, %Param ) = @_;

    # Check needed params.
    for my $Needed (qw(LayoutObject DynamicFields Ticket)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => "error",
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    my $LayoutObject = $Param{LayoutObject};
    my @DynamicFields  = @{ $Param{DynamicFields} };
    my %Ticket = %{ $Param{Ticket} };

    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

    my @DynamicFieldInfos;
    DYNAMICFIELD:
    for my $DynamicFieldConfig ( @DynamicFields ) {
        next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);

        # Skip the dynamic field if it is not designed for customer interface.
        my $IsCustomerInterfaceCapable = $DynamicFieldBackendObject->HasBehavior(
            DynamicFieldConfig => $DynamicFieldConfig,
            Behavior           => 'IsCustomerInterfaceCapable',
        );
        next DYNAMICFIELD if !$IsCustomerInterfaceCapable;

        if ($Param{ArticleID}) {
            my $Value = $DynamicFieldBackendObject->ValueGet(
                DynamicFieldConfig => $DynamicFieldConfig,
                ObjectID           => $Param{ArticleID},
            );

            next DYNAMICFIELD if !$Value;
            next DYNAMICFIELD if $Value eq "";
        }
        

        # Get print string for this dynamic field.
        my $ValueStrg = $DynamicFieldBackendObject->ReadableValueRender(
            DynamicFieldConfig => $DynamicFieldConfig,
            Value              => $Ticket{ 'DynamicField_' . $DynamicFieldConfig->{Name} },
        );

        my $Label = $LayoutObject->{LanguageObject}->Translate( $DynamicFieldConfig->{Label} );

        push @DynamicFieldInfos, {
            $DynamicFieldConfig->{Name} => $ValueStrg->{Title},
            Name                        => $DynamicFieldConfig->{Name},
            Value                       => $ValueStrg->{Value},
            Label                       => $Label,

            # Include unique parameter with dynamic field name in case of collision with others.
            #   Please see bug#13362 for more information.
            "DynamicField_$DynamicFieldConfig->{Name}" => $ValueStrg->{Title},
        }
    }

    $LayoutObject->Block(
        Name => 'DynamicFields'
    );

    for my $Field (@DynamicFieldInfos) {

        my ($DFConfig) = grep { $_->{Name} eq $Field->{Name} } @DynamicFields;

        # set field
        if ( $DFConfig->{FieldType} eq 'Set' ) {

            $LayoutObject->Block(
                Name => 'SetField',
            );

            $LayoutObject->Block(
                Name => 'DynamicFieldSetSeparator',
                Data => {
                    Name => $Field->{Name},
                },
            );

            my @IncludedFields = $Self->_GetIncludedFieldOrdered(
                Include => $DFConfig->{Config}{Include},
            );

            for my $IncludeField (@IncludedFields) {

                my $IncludeDFConfig = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet(
                    Name => $IncludeField,
                );
                my $ValueStrg = $DynamicFieldBackendObject->DisplayValueRender(
                    DynamicFieldConfig => $IncludeDFConfig,
                    Value              => $Ticket{ 'DynamicField_' . $IncludeDFConfig->{Name} },
                    LayoutObject       => $LayoutObject,

                    # no ValueMaxChars here, enough space available
                );

                my %IncludeField = (
                    $IncludeDFConfig->{Name} => $ValueStrg->{Title},
                    Name                     => $IncludeDFConfig->{Name},
                    Value                    => $ValueStrg->{Value},
                    Label                    => $IncludeDFConfig->{Label},

                    # Include unique parameter with dynamic field name in case of collision with others.
                    #   Please see bug#13362 for more information.
                    "DynamicField_$IncludeDFConfig->{Name}" => $ValueStrg->{Title},
                );

                $LayoutObject->Block(
                    Name => 'SetDynamicField',
                    Data => {
                        Label => $IncludeField{Label},
                    }
                );

                $LayoutObject->Block(
                    Name => 'SetDynamicFieldValue',
                    Data => {
                        Value => $IncludeField{Value},
                    },
                );
            }
        }

        # standard field
        else {
            $LayoutObject->Block(
                Name => 'StandardField',
                Data => {
                    Name  => $Field->{Name},
                    Value => $Field->{Value},
                },
            );
        }
    }

}

sub _GetIncludedFieldOrdered {
    my ( $Self, %Param ) = @_;

    my @Return;

    ITEM:
    for my $IncludeItem ( @{ $Param{Include} } ) {

        if ( $IncludeItem->{Grid} ) {
            for my $Row ( @{ $IncludeItem->{Grid}{Rows} } ) {

                COLUMN:
                for my $DFEntry ( $Row->@* ) {
                    next COLUMN if !$DFEntry->{DF};

                    push @Return, $DFEntry->{DF};
                }
            }
        }
        elsif ( $IncludeItem->{DF} ) {
            push @Return, $IncludeItem->{DF};
        }
    }

    return @Return;
}
    
1;
