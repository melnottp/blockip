#!/bin/bash
# ==========================================
# INSTALLATION BLACKLISTS IP AUTOMATIQUES
# ==========================================

echo "🔥 Installation des blacklists IP automatiques..."

# 1. Installation des dépendances
sudo apt update
sudo apt install -y ipset iptables-persistent curl wget

# 2. Créer le dossier de configuration
sudo mkdir -p /etc/blacklists

# 3. Script de mise à jour des blacklists
sudo tee /usr/local/bin/update-blacklists.sh << 'EOF'
#!/bin/bash

BLACKLIST_DIR="/etc/blacklists"
LOG_FILE="/var/log/blacklist-update.log"

echo "$(date): Mise à jour des blacklists" >> $LOG_FILE

# Fonction pour télécharger et appliquer une blacklist
update_blacklist() {
    local name=$1
    local url=$2
    local temp_file="/tmp/$name.tmp"
    
    echo "Téléchargement de $name..." >> $LOG_FILE
    
    if curl -s "$url" | grep -E '^[0-9]+\.' > "$temp_file"; then
        if [ -s "$temp_file" ]; then
            # Créer l'ipset si il n'existe pas
            if ! ipset list $name >/dev/null 2>&1; then
                ipset create $name hash:net
            fi
            
            # Vider l'ancien set
            ipset flush $name
            
            # Ajouter les nouvelles IPs
            while read ip; do
                ipset add $name $ip 2>/dev/null
            done < "$temp_file"
            
            # Appliquer la règle iptables si elle n'existe pas
            if ! iptables -C INPUT -m set --match-set $name src -j DROP 2>/dev/null; then
                iptables -I INPUT -m set --match-set $name src -j DROP
            fi
            
            echo "$name: $(wc -l < $temp_file) IPs ajoutées" >> $LOG_FILE
            mv "$temp_file" "$BLACKLIST_DIR/$name.list"
        else
            echo "Erreur: $name liste vide" >> $LOG_FILE
        fi
    else
        echo "Erreur: impossible de télécharger $name" >> $LOG_FILE
    fi
    
    rm -f "$temp_file"
}

# Spamhaus DROP (réseaux compromis)
update_blacklist "spamhaus_drop" "https://www.spamhaus.org/drop/drop.txt"

# DShield (IPs malveillantes)  
update_blacklist "dshield" "https://feeds.dshield.org/block.txt"

# Blocklist.de (attaques SSH/web)
update_blacklist "blocklist_de" "https://lists.blocklist.de/lists/all.txt"

# GreenSnow (scanners)
update_blacklist "greensnow" "https://blocklist.greensnow.co/greensnow.txt"

# Sauvegarder les règles iptables
if command -v netfilter-persistent >/dev/null; then
    netfilter-persistent save
elif command -v iptables-save >/dev/null; then
    iptables-save > /etc/iptables/rules.v4
fi

echo "$(date): Mise à jour terminée" >> $LOG_FILE
echo "Total IPs bloquées: $(iptables -L INPUT -v -n | grep 'match-set' | awk '{sum+=$1} END {print sum}')" >> $LOG_FILE
EOF

chmod +x /usr/local/bin/update-blacklists.sh

# 4. Premier téléchargement et application
echo "📥 Téléchargement initial des blacklists..."
sudo /usr/local/bin/update-blacklists.sh

# 5. Tâche cron pour mise à jour automatique (toutes les 6h)
echo "⏰ Configuration de la mise à jour automatique..."
(crontab -l 2>/dev/null; echo "0 */6 * * * /usr/local/bin/update-blacklists.sh") | crontab -

# 6. Script de vérification
sudo tee /usr/local/bin/blacklist-stats.sh << 'EOF'
#!/bin/bash

echo "📊 Statistiques des blacklists:"
echo "================================"

for set in spamhaus_drop dshield blocklist_de greensnow; do
    if ipset list $set >/dev/null 2>&1; then
        count=$(ipset list $set | grep -c '^[0-9]')
        echo "$set: $count IPs bloquées"
    fi
done

echo ""
echo "🔥 Règles iptables actives:"
iptables -L INPUT -v -n | grep 'match-set'

echo ""
echo "📈 Paquets bloqués aujourd'hui:"
iptables -L INPUT -v -n | grep 'match-set' | awk '{sum+=$1} END {print sum " paquets"}'
EOF

chmod +x /usr/local/bin/blacklist-stats.sh

# 7. Script pour vérifier une IP
sudo tee /usr/local/bin/check-ip.sh << 'EOF'
#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <IP>"
    exit 1
fi

IP=$1
echo "🔍 Vérification de l'IP: $IP"
echo "================================"

for set in spamhaus_drop dshield blocklist_de greensnow; do
    if ipset list $set >/dev/null 2>&1; then
        if ipset test $set $IP 2>/dev/null; then
            echo "❌ $IP trouvée dans $set"
        else
            echo "✅ $IP pas dans $set"
        fi
    fi
done
EOF

chmod +x /usr/local/bin/check-ip.sh

echo ""
echo "✅ Installation terminée !"
echo ""
echo "📋 Commandes utiles:"
echo "- Voir les stats: sudo /usr/local/bin/blacklist-stats.sh"
echo "- Vérifier une IP: sudo /usr/local/bin/check-ip.sh 1.2.3.4"
echo "- Voir les logs: sudo tail -f /var/log/blacklist-update.log"
echo "- Mise à jour manuelle: sudo /usr/local/bin/update-blacklists.sh"
echo ""
echo "🔄 Les listes se mettent à jour automatiquement toutes les 6h"

# Afficher les premières stats
echo ""
sudo /usr/local/bin/blacklist-stats.sh
